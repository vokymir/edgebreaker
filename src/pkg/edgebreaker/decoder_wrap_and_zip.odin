#+private file
package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"

/******************************* TYPES ****************************************/

/* 
Temporary values for connectivity pass.
Must not collide with ct.INVALID_CORNER.
*/
FREE_LEFT :: ct.Corner(-10)
FREE_RIGHT :: ct.Corner(-20)

/******************************* STRUCTS **************************************/

/*
Hole already found by S but the vertices not known yet.
*/
Pending_Hole :: struct {
	tip:   ct.Corner, // tip of S triangle
	first: ct.Vertex, // id of the first (tip) hole vertex
	len:   int, // #verts in hole
}

Wrap_a_Zip_State :: struct {
	//
	using common:  Decoder_Common_State,
	geometry:      Decoder_Geometry_State,

	// lookups prepared from topology
	holes:         map[ct.Corner]int, // map tip corner -> hole len
	glues:         map[ct.Corner]ct.Corner, // map corner -> corner (arrival to S-left)

	// connectivity pass
	gate_stack:    [dynamic]Gate,
	sym_pos:       int,
	last_tri:      ct.Triangle,
	last_vertex:   ct.Vertex,
	pending_holes: [dynamic]Pending_Hole,
}

init_wz :: proc(
	wz: ^Wrap_a_Zip_State,
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	n_triangles := len(em.symbols)
	n_vertices := len(em.vertices)

	prepare_corner_table(t, n_vertices, n_triangles, loc)

	wz^ = Wrap_a_Zip_State {
		holes         = make(map[ct.Corner]int, allocator, loc),
		glues         = make(map[ct.Corner]ct.Corner, allocator, loc),
		//
		gate_stack    = make([dynamic]Gate, allocator, loc),
		sym_pos       = 0,
		last_tri      = ct.INVALID_TRIANGLE,
		last_vertex   = ct.INVALID_VERTEX,
		pending_holes = make([dynamic]Pending_Hole, allocator, loc),
	}

	init_dcs(&wz.common, em, t, allocator)
	init_dgs(&wz.geometry, n_vertices, n_triangles, em.vertex_codec, allocator, loc)

	prepare_topology_lookups(wz, em.topology[:])
}

/*
Transform topology entries into maps for O(1) lookup time.
*/
prepare_topology_lookups :: proc(wz: ^Wrap_a_Zip_State, topology: []Topology_Entry) {
	for top in topology {
		s, arrival := corners_from_topology(top)

		wz.glues[arrival] = s

		if top.hole_len > 0 {
			s_tip := side_corner(s, .RIGHT)
			wz.holes[s_tip] = top.hole_len
		}
	}
}

destroy_wz :: proc(wz: ^Wrap_a_Zip_State, loc := #caller_location) {
	delete(wz.holes, loc)
	delete(wz.glues, loc)
	delete(wz.pending_holes, loc)

	destroy_dcs(&wz.common, loc)
	destroy_dgs(&wz.geometry, loc)
}

/********************************** ENTRY *************************************/

@(private)
decode_wrap_and_zip :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	wz: Wrap_a_Zip_State
	init_wz(&wz, em, t, allocator, loc)
	defer destroy_wz(&wz, loc)

	// store component starts
	starts := make([dynamic]ct.Corner, 0, len(em.components), allocator, loc)
	defer delete(starts, loc)

	// pass 1: connectivity
	for comp in em.components {
		append(&starts, decode_component_connectivity(&wz, comp))
	}
	assert(wz.sym_pos == len(wz.symbols), "unused symbols")
	assert(int(wz.last_vertex + 1) == len(em.vertices), "missing vertex")

	finalize_corner_table(&wz, loc)
	assert_corner_table_consistent(t^)

	// pass 2: geometry
	decode_geometry(&wz.common, &wz.geometry, starts[:], em.components[:])
}

/******************************* PASS 1: CONNECTIVITY *************************/

/*
Returns:
- tip corner of first triangle
*/
decode_component_connectivity :: proc(wz: ^Wrap_a_Zip_State, comp: Component_Info) -> ct.Corner {
	start, first_vertex := begin_component(wz, comp)

	first_tri := int(wz.last_tri + 1)
	decode_component_triangles(wz, start)
	last_tri := int(wz.last_tri + 1)

	assert_component_border_edges(wz^, first_tri, last_tri, comp)
	finish_component(wz, start, first_vertex, comp)

	return start
}

/*
Reserve vertices for initial triangle and maybe outer boundary.

Returns:
- start: tip of first triangle
- first_vertex: id of gs (1st component vertex, absolute position)
*/
begin_component :: proc(
	wz: ^Wrap_a_Zip_State,
	comp: Component_Info,
) -> (
	start: ct.Corner,
	first_vertex: ct.Vertex,
) {
	log.debug("begin component", comp)
	start = peek_next_tip(wz^)

	if comp.outer_boundary > 0 { 	// BOUNDARY COMPONENT
		first_vertex = begin_boundary_component(wz, start, comp.outer_boundary)
	} else { 	// CLOSED COMPONENT
		first_vertex = begin_closed_component(wz, start)
	}

	return start, first_vertex
}

/*
reserve border vertex ids, process gs,ge
the assigning of vertex ids is done in finish_component
*/
begin_boundary_component :: proc(
	wz: ^Wrap_a_Zip_State,
	tip: ct.Corner,
	n_border: int,
) -> ct.Vertex {
	first := reserve_vertex_ids(wz, n_border)

	wz.t.c2v[gate_start(tip)] = first
	wz.t.c2v[gate_end(tip)] = first + ct.Vertex(n_border - 1)

	return first
}

begin_closed_component :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Vertex {
	first := reserve_vertex_ids(wz, 2)

	wz.t.c2v[gate_start(tip)] = first
	wz.t.c2v[gate_end(tip)] = first + 1
	wz.t.op[tip] = FREE_LEFT

	return first
}

/*
Main connectivity loop, iterates over triangles.
*/
decode_component_triangles :: proc(wz: ^Wrap_a_Zip_State, start: ct.Corner) {
	tip := new_triangle(wz) // initial triangle
	assert(tip == start, "component must start on the next free triangle")

	for {
		// glue depends on triangle, not the symbol
		glue_triangle(wz, tip)

		symbol := read_symbol(wz)
		edge := apply_symbol(wz, tip, symbol)
		if edge == ct.INVALID_CORNER {return} 	// finished component

		assert(!exist(wz.t.op[edge]), "enc/dec mismatch: next gate is already linked")
		tip = attach_triangle(wz, edge)
	}
}

/*
Create new triangle. It is attached to "edge".

Returns:
- tip: tip of the new triangle
*/
attach_triangle :: proc(wz: ^Wrap_a_Zip_State, edge: ct.Corner) -> (tip: ct.Corner) {
	t := wz.t
	tip = new_triangle(wz)

	t.op[edge] = tip
	t.op[tip] = edge

	t.c2v[gate_start(tip)] = t.c2v[prev(edge)]
	t.c2v[gate_end(tip)] = t.c2v[next(edge)]

	return tip
}

/********************************* CLERS **************************************/

/*
Returns:
- edge: corner which the next triangle should be attached to
  INVALID_CORNER = component is finished
*/
apply_symbol :: proc(
	wz: ^Wrap_a_Zip_State,
	tip: ct.Corner,
	symbol: Operation,
) -> (
	edge: ct.Corner,
) {
	switch symbol {
	case .C:
		edge = apply_C(wz, tip)
	case .L:
		edge = apply_L(wz, tip)
	case .R:
		edge = apply_R(wz, tip)
	case .S:
		edge = apply_S(wz, tip)
	case .E:
		edge = apply_E(wz, tip)
	}
	return edge
}

// new vertex, left is open, return right
apply_C :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Corner {
	set_free(wz.t, left_edge(tip), FREE_LEFT)
	wz.t.c2v[tip] = reserve_vertex_id(wz)
	return right_edge(tip)
}
// left triangle already exists, close it (zip), continue right
apply_L :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Corner {
	set_free(wz.t, left_edge(tip), FREE_RIGHT)
	zip_if_free_right(wz, left_edge(tip))
	return right_edge(tip)
}
// right triangle already exists, continue left
apply_R :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Corner {
	set_free(wz.t, right_edge(tip), FREE_RIGHT)
	return left_edge(tip)
}
// split: push left, return right
apply_S :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Corner {
	push_gate(wz, left_edge(tip))
	return right_edge(tip)
}
// end: close sides, zip, pop gate_stack
apply_E :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) -> ct.Corner {
	l := left_edge(tip)
	r := right_edge(tip)
	set_free(wz.t, r, FREE_RIGHT)
	set_free(wz.t, l, FREE_RIGHT)
	zip_if_free_right(wz, l) // might be no-op if was previously glued
	zip_if_free_right(wz, r) // might be no-op if l was zipped
	return pop_unlinked_gate(wz)
}

/*
Mark edge as free ONLY if it isn't already linked.
*/
set_free :: proc(t: ^ct.Corner_Table, edge, mark: ct.Corner) {
	if !exist(t.op[edge]) {t.op[edge] = mark}
}

/****************************** HOLES & HANDLES *******************************/

/*
Check everything:
a) is a hole? if so, reserve
b) is arrival? if so, glue & try zip
*/
glue_triangle :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) {
	reserve_hole_vertices(wz, tip)
	glue_side(wz, side_corner(tip, .RIGHT))
	glue_side(wz, side_corner(tip, .LEFT))
}

/*
If tip is on hole: reserve vertices (assigned in finish_component)
*/
reserve_hole_vertices :: proc(wz: ^Wrap_a_Zip_State, tip: ct.Corner) {
	n, is_hole := wz.holes[tip]
	if !is_hole {return}

	first := reserve_vertex_ids(wz, n)
	wz.t.c2v[tip] = first
	append(&wz.pending_holes, Pending_Hole{tip = tip, first = first, len = n})
}

/*
If corner is arrival corner, glue it - and try to zip.
*/
glue_side :: proc(wz: ^Wrap_a_Zip_State, corner: ct.Corner) {
	t := wz.t

	s_left, is_arrival := wz.glues[corner]
	if !is_arrival {return}

	glue_corners(wz.t, s_left, corner)

	unify_vertices(t, next(corner), prev(s_left))
	unify_vertices(t, prev(corner), next(s_left))

	zippi := zip_next(t^, ct.INVALID_CORNER, corner)
	zip_if_free_right(wz, zippi)
}

/*
Corners (at least one) were just assigned the same vertex. Give it to the whole
ring.
*/
unify_vertices :: proc(t: ^ct.Corner_Table, a, b: ct.Corner) {
	va, vb := t.c2v[a], t.c2v[b]
	if va == ct.INVALID_VERTEX && vb == ct.INVALID_VERTEX {return}

	valid_case := va == vb || va == ct.INVALID_VERTEX || vb == ct.INVALID_VERTEX
	assert(valid_case, "glued corners belong to different vertices")

	known := va if va != ct.INVALID_VERTEX else vb
	set_ring(t, a, known)
}

finish_component :: proc(
	wz: ^Wrap_a_Zip_State,
	start: ct.Corner,
	first_vertex: ct.Vertex,
	comp: Component_Info,
) {
	for h in wz.pending_holes {
		set_border(wz.t, h.tip, h.first, h.len)
	}
	clear(&wz.pending_holes)

	if comp.outer_boundary > 0 {
		set_border(wz.t, gate_start(start), first_vertex, comp.outer_boundary)
	}
}

/********************************** ZIP ***************************************/

/*
Zip only if a waiting pair from right exists. (avoids already glued edges)
*/
zip_if_free_right :: proc(wz: ^Wrap_a_Zip_State, edge: ct.Corner) {
	if wz.t.op[edge] == FREE_RIGHT {zip(wz, edge)}
}

/*
Link the FREE-R edge (c)with FREE-L waiting pair, then continue if possible.
*/
zip :: proc(wz: ^Wrap_a_Zip_State, c: ct.Corner) {
	t := wz.t
	c := c

	for t.op[c] == FREE_RIGHT {
		b := zip_pair(t^, c)
		if t.op[b] != FREE_LEFT {return}

		t.op[c], t.op[b] = b, c
		relabel_fan(t, b, c)

		c = zip_next(t^, b, c)
	}
}

/*
Find first corner on vertex_of(c) which isn't linked.
*/
zip_pair :: proc(t: ct.Corner_Table, c: ct.Corner) -> ct.Corner {
	b := next(c)

	// go around the common vertex and find the opposite corner
	for steps := 0; exist(t.op[b]); steps += 1 {
		assert(steps < len(t.op), "zip: endless walk (corrupted input?)")
		b = next(t.op[b])
	}

	return b
}

/*
Set every corner around vertex c2v[prev(b)] to has that vertex in c2v table.
prev(b) must be the vertex v
*/
relabel_fan :: proc(t: ^ct.Corner_Table, b, c: ct.Corner) {
	q := next(c)
	v := t.c2v[prev(b)]

	if v == ct.INVALID_VERTEX {v = t.c2v[q]}
	if v == ct.INVALID_VERTEX {return}

	set_ring(t, q, v)
}

/*
After c and b were linked, where to continue zipping?
the free end on the other side of c
*/
zip_next :: proc(t: ct.Corner_Table, b, c: ct.Corner) -> ct.Corner {
	c := prev(c)

	for steps := 0; exist(t.op[c]) && c != b; steps += 1 {
		assert(steps < len(t.op), "zip: endless walk (corrupted input?)")
		c = prev(t.op[c])
	}

	return c
}

/******************************** CORNER TABLE ********************************/

/*
not linked edge = border. fill t.v2c and assert nothing unresolved
*/
finalize_corner_table :: proc(wz: ^Wrap_a_Zip_State, loc := #caller_location) {
	t := wz.t

	for &o in t.op {
		if o < 0 {o = ct.INVALID_CORNER}
	}

	fill_v2c(t, loc)
}

/****************************** Helpers ***************************************/

exist :: #force_inline proc(c: ct.Corner) -> bool {return c >= 0}

read_symbol :: proc(wz: ^Wrap_a_Zip_State) -> Operation {
	assert(wz.sym_pos < len(wz.symbols), "ran out of symbols")
	s := wz.symbols[wz.sym_pos]
	wz.sym_pos += 1
	return s
}

reserve_vertex_id :: proc(wz: ^Wrap_a_Zip_State) -> ct.Vertex {
	wz.last_vertex += 1
	return wz.last_vertex
}

// return the first id
reserve_vertex_ids :: proc(wz: ^Wrap_a_Zip_State, n: int) -> ct.Vertex {
	first := wz.last_vertex + 1
	wz.last_vertex += ct.Vertex(n)
	return first
}

// tip of new (next) triangle
peek_next_tip :: proc(wz: Wrap_a_Zip_State) -> ct.Corner {
	return ct.Corner(3 * (wz.last_tri + 1))
}

// count a new triangle, return tip
new_triangle :: proc(wz: ^Wrap_a_Zip_State) -> ct.Corner {
	tip := peek_next_tip(wz^)
	wz.last_tri += 1
	return tip
}

/*
Pushes gate to wz.gate_stack.
*/
push_gate :: #force_inline proc(wz: ^Wrap_a_Zip_State, gate: ct.Corner) {
	append(&wz.gate_stack, Gate(gate))
}

/*
Pop gate stack until not linked gate is found.
*/
pop_unlinked_gate :: #force_inline proc(wz: ^Wrap_a_Zip_State) -> ct.Corner {
	for len(wz.gate_stack) > 0 {
		candidate := ct.Corner(pop(&wz.gate_stack))

		if !exist(wz.t.op[candidate]) {return candidate}
	}
	return ct.INVALID_CORNER
}

/***************************** Asserts ****************************************/

/*
Component must have as many border edges as outer boundary + all holes.
*/
@(disabled = ODIN_DISABLE_ASSERT)
assert_component_border_edges :: proc(
	wz: Wrap_a_Zip_State,
	first, end: int,
	comp: Component_Info,
) {
	expected := comp.outer_boundary
	for ph in wz.pending_holes {
		expected += ph.len
	}

	assert_border_edges_count(wz.t^, first, end, expected)
}
