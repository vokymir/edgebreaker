#+private file
package edgebreaker

import ct "../corner_table"
import "core:log"

/************************************ Structs *********************************/

Spirale_Reversi_State :: struct {
	using dcs:   Decoder_Common_State,
	geo:         Decoder_Geometry_State,

	// step of S -> hole length (0 for plain handle)
	// every S is glued from the start
	handle_s:    map[int]int,

	// connectivity pass
	gate_stack:  [dynamic]Gate,
	// vertex labelling
	last_vertex: ct.Vertex,
}

/******************************* Structs maintenance **************************/

init_sr :: proc(
	sr: ^Spirale_Reversi_State,
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	n_triangles := len(em.symbols)
	n_vertices := len(em.vertices)

	prepare_corner_table(t, n_vertices, n_triangles, loc)

	init_dcs(&sr.dcs, em, t, allocator)
	init_dgs(&sr.geo, n_vertices, n_triangles, em.vertex_codec, allocator, loc)

	sr.handle_s = make(map[int]int, allocator, loc)
	sr.gate_stack = make([dynamic]Gate, allocator, loc)
	sr.last_vertex = ct.INVALID_VERTEX

	glue_topology(sr, em.topology[:])
}

/*
Glue topology before and store S -> hole_len in sr.handle_s.
*/
glue_topology :: proc(sr: ^Spirale_Reversi_State, topology: []Topology_Entry) {
	for top in topology {
		s_left, arrival := corners_from_topology(top)

		glue_corners(sr.t, s_left, arrival)
		sr.handle_s[top.s_step] = top.hole_len
	}
}

destroy_sr :: proc(sr: ^Spirale_Reversi_State, loc := #caller_location) {
	delete(sr.handle_s, loc)
	delete(sr.gate_stack, loc)
	destroy_dgs(&sr.geo, loc)
	destroy_dcs(&sr.dcs)
}

/*************************** Main Procedures **********************************/

@(private)
decode_spirale_reversi :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	sr: Spirale_Reversi_State
	init_sr(&sr, em, t, allocator, loc)
	defer destroy_sr(&sr, loc)

	starts := find_component_starts(sr, len(em.components), allocator, loc)
	defer delete(starts, loc)
	assert(len(starts) == len(em.components), "clers string and component list disagree")

	// pass 1 (REVERSE): connectivity
	for comp, i in em.components {
		first, end := component_triangles(starts[:], i, len(em.symbols))
		log.debug("component", i, "triangles", first, "..<", end)

		connect_component(&sr, first, end, comp)
		assert_component_border_edges(sr, first, end, comp)
		label_component_vertices(&sr, first, end, comp)
	}
	assert(int(sr.last_vertex + 1) == len(em.vertices), "missing vertex")

	fill_v2c(t, loc)
	assert_corner_table_consistent(t^)

	// pass 2 (FORWARD): geometry
	decode_geometry(&sr.dcs, &sr.geo, starts[:], em.components[:])
}

/**************************** Component detection *****************************/

/*
Find all components starts by counting S and E. handle/hole S does not count.

Returns:
- tip corner of the first triangle of every component
*/
find_component_starts :: proc(
	sr: Spirale_Reversi_State,
	n_components: int,
	allocator := context.allocator,
	loc := #caller_location,
) -> [dynamic]ct.Corner {
	starts := make([dynamic]ct.Corner, 0, n_components, allocator, loc)

	first := 0
	open := 0
	for symbol, step in sr.symbols {
		switch symbol {
		case .S:
			if step not_in sr.handle_s {open += 1}
		case .E:
			if open > 0 {
				open -= 1
			} else {
				append(&starts, ct.Corner(3 * first))
				first = step + 1
			}
		case .C, .L, .R:
		}
	}
	assert(first == len(sr.symbols), "last component is not closed by E")

	return starts
}

/*
Components are next to each other, i-th ends where (i+1)-th starts.

Returns:
- <first, end) triangles of i-th component
*/
component_triangles :: proc(starts: []ct.Corner, i, n_triangles: int) -> (first, end: int) {
	first = int(ct.c2t(starts[i]))

	if i + 1 < len(starts) {
		end = int(ct.c2t(starts[i + 1]))
	} else {end = n_triangles}

	return first, end
}

/******************************* PASS 1: CONNECTIVITY *************************/

/*
Connect one component consisting of symbols at indices <first, end).

*/
connect_component :: proc(sr: ^Spirale_Reversi_State, first, end: int, comp: Component_Info) {
	assert(len(sr.gate_stack) == 0, "gate stack must be empty between components")

	// successor = tip of triangle step+1 (last triangle = E => INVALID)
	successor := ct.INVALID_CORNER

	for step := end - 1; step >= first; step -= 1 {
		tip := ct.Corner(3 * step)

		switch sr.symbols[step] {
		case .C:
			reverse_C(sr, tip, successor)
		case .L:
			reverse_L(sr, tip, successor)
		case .R:
			reverse_R(sr, tip, successor)
		case .S:
			reverse_S(sr, tip, successor, step)
		case .E:
			reverse_E(sr, successor)
		}

		successor = tip
	}
	assert(len(sr.gate_stack) == 0, "E without matching S")

	if comp.outer_boundary == 0 {close_first_triangle(sr, first)}
}

/*
new vertex: 
- right edge continues to the successor
- left edge is star-closed by the tip vtx
*/
reverse_C :: proc(sr: ^Spirale_Reversi_State, tip, successor: ct.Corner) {
	glue_successor(sr, successor, right_edge(tip))
	close_star(sr, tip)
}

// left was glued by its own C (or topology/border)
reverse_L :: proc(sr: ^Spirale_Reversi_State, tip, successor: ct.Corner) {
	glue_successor(sr, successor, right_edge(tip))
}

// right was glued by its own C (or topology/border)
reverse_R :: proc(sr: ^Spirale_Reversi_State, tip, successor: ct.Corner) {
	glue_successor(sr, successor, left_edge(tip))
}

/*
split: 
- right edge continues to the successor
- left edge is either already glued (handle/hole, from topology) or belongs to
  the gate waiting on the stack.
*/
reverse_S :: proc(sr: ^Spirale_Reversi_State, tip, successor: ct.Corner, step: int) {
	glue_successor(sr, successor, right_edge(tip))

	if step in sr.handle_s {return}
	glue_corners(sr.t, left_edge(tip), pop_gate(sr))
}

/*
end: nothing to glue. 
triangle after it starts the left branch of some S, push it on stack

(no successor = end of component.)
*/
reverse_E :: proc(sr: ^Spirale_Reversi_State, successor: ct.Corner) {
	if successor != ct.INVALID_CORNER {push_gate(&sr.gate_stack, successor)}
}

/*
the gate of the successor is the given edge of the current triangle
*/
glue_successor :: proc(sr: ^Spirale_Reversi_State, successor, edge: ct.Corner) {
	assert(successor != ct.INVALID_CORNER, "triangle has no successor (corrupted clers?)")
	glue_corners(sr.t, successor, edge)
}

/*
pass 1: S needs exactly one waiting left branch.
*/
pop_gate :: #force_inline proc(sr: ^Spirale_Reversi_State) -> ct.Corner {
	assert(len(sr.gate_stack) > 0, "S without matching E (corrupted clers?)")
	return ct.Corner(pop(&sr.gate_stack))
}

/********************************* STARS **************************************/

/*
The tip of C is a vertex with almost-full fan (everything is already done)
except this triangle. Glue those two edges together
*/
close_star :: proc(sr: ^Spirale_Reversi_State, tip: ct.Corner) {
	pair := open_end_of_fan(sr.t^, tip)
	glue_corners(sr.t, left_edge(tip), pair)
}

/*
Closed component only.

gate edge gs-ge is the last edge not glued yet

the fan around gs has two ends: the gate and the pair
*/
close_first_triangle :: proc(sr: ^Spirale_Reversi_State, first_step: int) {
	assert(sr.symbols[first_step] == .C, "first triangle of closed component must be C")

	tip := ct.Corner(3 * first_step)
	pair := open_end_of_fan(sr.t^, gate_start(tip))
	glue_corners(sr.t, tip, pair)
}

/*
Walk around the vertex of corner c to the right until the fan ends.

Returns:
- the corner opposite the first edge which is not glued (open end of the fan)
*/
open_end_of_fan :: proc(t: ct.Corner_Table, c: ct.Corner) -> ct.Corner {
	last, is_open := ct.rightmost(t, c)
	assert(is_open, "fan is already closed, there is no gap to glue (corrupted input?)")
	return next(last)
}

/******************************* VERTEX IDS ***********************************/

/*
give ids to all vertices of one component, in the order the encoder emitted them:

1. outer boundary (gs -> ... -> ge) or just gs, ge
2. foreach (tip of C || hole of every boundary S)
*/
label_component_vertices :: proc(
	sr: ^Spirale_Reversi_State,
	first, end: int,
	comp: Component_Info,
) {
	t := sr.t
	first_tip := ct.Corner(3 * first)

	if comp.outer_boundary > 0 {
		first_id := label_border(sr, gate_start(first_tip), comp.outer_boundary)
		last_id := first_id + ct.Vertex(comp.outer_boundary - 1)
		assert(t.c2v[gate_end(first_tip)] == last_id, "ge must be the last outer boundary vertex")
	} else {
		set_ring(t, gate_start(first_tip), new_vertex_id(sr))
		set_ring(t, gate_end(first_tip), new_vertex_id(sr))
	}

	for step in first ..< end {
		tip := ct.Corner(3 * step)

		switch sr.symbols[step] {
		case .C:
			set_ring(t, tip, new_vertex_id(sr))
		case .S:
			hole_len := sr.handle_s[step] or_else 0
			if hole_len > 0 {label_border(sr, tip, hole_len)}
		case .L, .R, .E:
		}
	}
}

/*
(the same as encoder's visit_hole).

Returns:
- id of the first vertex
*/
label_border :: proc(sr: ^Spirale_Reversi_State, c: ct.Corner, count: int) -> ct.Vertex {
	first_id := reserve_vertex_ids(sr, count)
	set_border(sr.t, c, first_id, count)
	return first_id
}

new_vertex_id :: proc(sr: ^Spirale_Reversi_State) -> ct.Vertex {
	return reserve_vertex_ids(sr, 1)
}

// return the first id
reserve_vertex_ids :: proc(sr: ^Spirale_Reversi_State, n: int) -> ct.Vertex {
	first := sr.last_vertex + 1
	sr.last_vertex += ct.Vertex(n)
	return first
}

/***************************** Asserts ****************************************/

/*
Component must have as many border edges as outer boundary + all holes.
*/
@(disabled = ODIN_DISABLE_ASSERT)
assert_component_border_edges :: proc(
	sr: Spirale_Reversi_State,
	first, end: int,
	comp: Component_Info,
) {
	expected := comp.outer_boundary
	for step in first ..< end {
		expected += sr.handle_s[step] or_else 0
	}

	assert_border_edges_count(sr.t^, first, end, expected)
}
