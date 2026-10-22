package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:slice"

Vector3 :: [3]f32

// TODO: write assert
// Per component, assert that the number of topology entries equals 2 − χ
// (or 1 − χ if the component has a boundary).

/***************************** Structs ****************************************/

Encoder_State :: struct {
	// for destroy
	allocator:     runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:  []Mark,
	// in which step a triangle was discovered (0=never)
	tri_step:      []int,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:    [dynamic]ct.Corner,
	// store S step -> number of hole vertices
	hole_len_of_s: map[int]int,

	// predicts position of next vertex
	predictor:     Predictor,

	// ptr to resulting mesh
	em:            ^Encoded_Mesh,
}

init_es :: proc(
	es: ^Encoder_State,
	n_vertices, n_triangles: int,
	predictor := Predictor_None,
	allocator := context.allocator,
	loc := #caller_location,
) {
	es.vertex_marks = make([]Mark, n_vertices, allocator, loc)
	slice.fill(es.vertex_marks[:], Mark.NOT_VISITED)

	es.tri_step = make([]int, n_triangles, allocator, loc)

	es.gate_stack = make([dynamic]ct.Corner, allocator, loc)

	es.predictor = predictor
	es.allocator = allocator
}

/*
WARN: caller must deallocate predictor (if necessary)
*/
destroy_es :: proc(es: ^Encoder_State, loc := #caller_location) {
	delete(es.vertex_marks, es.allocator, loc)
	delete(es.tri_step, es.allocator, loc)
	delete(es.gate_stack, loc)
}

/*
If is not hole, hole_len == 0
*/
Topology_Entry :: struct {
	s_corner:       ct.Corner,
	arrival_corner: ct.Corner,
	hole_len:       int,
}

/*
Store the encoded mesh as a sequence of consecutive CLERS symbols and a list of
all vertices in the order of appeareance.
*/
Encoded_Mesh :: struct {
	symbols:  [dynamic]Operation,
	vertices: [dynamic]Vector3,
	topology: [dynamic]Topology_Entry,
}

init_em :: proc(
	em: ^Encoded_Mesh,
	n_symbols: int = 0,
	n_vertices: int = 0,
	es: ^Encoder_State = nil,
	allocator := context.allocator,
	loc := #caller_location,
) {
	em.symbols = make([dynamic]Operation, 0, n_symbols, allocator, loc)
	em.vertices = make([dynamic]Vector3, 0, n_vertices, allocator, loc)
	em.topology = make([dynamic]Topology_Entry, 0, 0, allocator, loc)

	if es != nil {
		es.em = em
	}
}

destroy_em :: proc(em: ^Encoded_Mesh, loc := #caller_location) {
	delete(em.symbols, loc)
	delete(em.vertices, loc)
	delete(em.topology, loc)
}

Operation :: enum {
	// finds new vertex
	C, // create
	// traverse the spanning tree
	L, // left
	R, // right
	// parantheses
	S, // split
	E, // end
}

/*
Marks vertices as the algorithm goes through the mesh.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
	HOLE,
}

/***************************** Compression ************************************/

compress :: proc {
	compress_ct,
}

/*
Compress mesh represented via corner table and use Encoder_State.handler to
handle (store/send) data.
The encoder_state struct must be initialized before.

The caller is responsible for freeing returned em.
*/
@(private, require_results)
compress_ct :: proc(t: ct.Corner_Table, es: ^Encoder_State) -> (ok := false, em: ^Encoded_Mesh) {
	log.debug(t.geometry)

	em = new(Encoded_Mesh)
	init_em(em, len(t.vertices) / 3, len(t.geometry), es)

	index, boundary_component, component_found := next_component(es.vertex_marks, t)

	for component_found { 	// for all components
		log.debug("component found on", index)

		//     v                             v      which is handled
		//   /  \     OR this may happen:  /  \     in the if on_boundary{}
		// gs -- ge                      ge -- gs   case
		// as in gate start & gate end
		gs, on_boundary := ct.boundary_corner_of_vertex(t, ct.Vertex(index))
		gate := gate_from_corner(t, on_boundary, gs)

		log.debug("gate is", on_boundary ? "" : "not", "on boundary")

		// special case for open-meshes: must find boundary
		// TODO: redo so it handles also holes
		if boundary_component {
			log.debug("component has boundary")
			if !find_all_boundary_edges(es, t, gate) {
				return false, em
			}
		}

		// TODO: process gate as pure C???
		// gate = initial_triangle(es, t, gate)

		// TODO: decomposition
		for gate != ct.INVALID_CORNER { 	// for all triangles in 1 component
			log.debug("gate is on corner", gate)

			step := len(es.em.symbols)
			check_handles(es, t, gate, step)
			es.tri_step[ct.triangle_of_corner(gate)] = step + 1

			right := ct.opposite_corner(t, ct.next_corner(gate))
			left := ct.opposite_corner(t, ct.prev_corner(gate))
			right_done :=
				right == ct.INVALID_CORNER || es.tri_step[ct.triangle_of_corner(right)] != 0
			left_done := left == ct.INVALID_CORNER || es.tri_step[ct.triangle_of_corner(left)] != 0

			switch {
			case is_marked(es^, t, gate, .NOT_VISITED):
				gate = C(es, t, gate)
			case right_done && left_done:
				emit_symbol(es, .E)
				gate = pop_unvisited(es)
			case right_done:
				emit_symbol(es, .R); gate = left
			case left_done:
				emit_symbol(es, .L); gate = right
			case:
				gate = S(es, t, gate)
			}

		} // while the current vertex is in any not visited triangle

		// find another unvisited vertex, ie another mesh
		index, boundary_component, component_found = next_component(
			es.vertex_marks,
			t,
			index,
			boundary_component,
		)
	}

	return true, em
}

C :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) -> ct.Corner {
	emit_symbol(es, .C)
	emit_vertex(es, ct.corner_position(t, gate))

	mark(es, t, gate, .VISITED)

	right := ct.opposite_corner(t, ct.next_corner(gate))
	return right
}

// TODO: impl
// should it gets step or calculate by itself?
S :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) -> ct.Corner {

	if is_marked(es^, t, gate, .HOLE) {

		// find all hole vertices & mark with VISITED
		// store es.hole_len_of_s[step] = ...
		// convention: triangle gate is 0, next is 1, next-next(=prev) is 2
		// TODO: mention this convention somewhere
	}

	return ct.INVALID_CORNER
}

check_handles :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner, step: int) {
	// the two non-gate edges: (corner next(gate), k=1) is the right edge,
	// (corner prev(gate), k=2) is the left edge
	sides := [2]struct {
		edge_corner: ct.Corner,
		k:           ct.Corner,
	}{{ct.next_corner(gate), 1}, {ct.prev_corner(gate), 2}}

	for s in sides {
		n := ct.opposite_corner(t, s.edge_corner)
		if n == ct.INVALID_CORNER {continue} 	// mesh border

		n_step := es.tri_step[ct.triangle_of_corner(n)]
		if n_step == 0 {continue} 	// not visited yet
		if es.em.symbols[n_step - 1] != .S {continue}

		// reached an S triangle from the side: this can only be its left edge
		append(
			&es.em.topology,
			Topology_Entry {
				s_corner       = ct.Corner(3 * (n_step - 1) + 2),
				arrival_corner = ct.Corner(3 * step + int(s.k)),
				hole_len       = es.hole_len_of_s[n_step - 1], // 0 if absent
			},
		)
	}

}

pop_unvisited :: proc(es: ^Encoder_State) -> ct.Corner {
	for {
		if len(es.gate_stack) == 0 {return ct.INVALID_CORNER}

		candidate := pop(&es.gate_stack)

		// TODO: candidate for clarity proc
		if es.tri_step[ct.triangle_of_corner(candidate)] == 0 {
			return candidate
		}
	}
}

/****************************** General decomposition *************************/

/*
Find all boundary edges (ie corners which are in the same triangle and opposite
to those edges. Mark their vertices as .VISITED and emit their position starting
with G counter-clockwise to D.

      C    F      'initial' is the corner "under" B, ie D--G
    /  \ /  \     all other corners/edges will there be referenced
   A -- B -- E    by their vertices LETTERS - orientation may be
  / \  /x\  / \   induced as every triangle is counter clock-wise oriented
H -- D -- G -- I

*/
// TODO: rework for new style
@(private = "file")
find_all_boundary_edges :: proc(
	es: ^Encoder_State,
	t: ct.Corner_Table,
	initial: ct.Corner,
) -> (
	ok: bool,
) {
	if initial == ct.INVALID_CORNER {return false}

	dg := initial
	gi, found := ct.next_boundary_corner(t, dg)
	if !found {return false}

	for {
		// 1. mark & emit current right vertex
		bd := ct.prev_corner(dg)

		mark(es, t, bd, .VISITED)

		pos := ct.corner_position(t, bd)
		emit_vertex(es, pos)

		// 2. search one edge to the right (counter-clockwise)
		ie, found := ct.next_boundary_corner(t, gi)
		if !found {return false}

		// 3. save link
		// connect_boundary(es, dg, gi)

		// 4. advance to next edge
		dg = gi
		gi = ie

		if dg == initial {break}
	}

	return true
}

/******************************* Clarity helpers ******************************/

mark :: proc(es: ^Encoder_State, t: ct.Corner_Table, c: ct.Corner, mark: Mark) {
	es.vertex_marks[ct.vertex_of_corner(t, c)] = mark
}

is_marked :: proc(es: Encoder_State, t: ct.Corner_Table, c: ct.Corner, mark: Mark) -> bool {
	return es.vertex_marks[ct.vertex_of_corner(t, c)] == mark
}

emit_symbol :: proc(es: ^Encoder_State, symbol: Operation) {
	append(&es.em.symbols, symbol)
}

emit_vertex :: proc(es: ^Encoder_State, pos_or_correction: Vector3) {
	append(&es.em.vertices, pos_or_correction)
}

/****************************** Traversal helpers *****************************/

/*
Find next component ie next unmarked vertex in marks. If s_f_f_b is true, it
will prefer boundary vertices. If not, it will go linear from start (default=0)
to end.

Returns:
- index: Index in marks of the first found component
*/
@(private = "file")
next_component :: proc(
	marks: []Mark,
	t: ct.Corner_Table,
	start := 0,
	search_first_for_boundary := true,
) -> (
	index: int,
	found_in_boundary: bool,
	found: bool,
) {
	start := start

	log.debug(marks)
	if search_first_for_boundary {
		for mark, i in marks[start:] {
			if mark == .NOT_VISITED && ct.vertex_is_on_boundary(t, ct.Vertex(i)) {
				log.debug("found on boundary:", i)
				return start + i, true, true
			}
		}
		// not found on boundary, continue search in closed mesh
		log.debug("not found on boundary")
		start = 0
	}

	for mark, i in marks[start:] {
		if mark == .NOT_VISITED {
			log.debug("found")
			return start + i, false, true
		}
	}

	log.debug("not found")
	return -1, false, false
}

/*
From a corner which might be on boundary return the corresponding gate vertex.
*/
@(private = "file")
gate_from_corner :: proc(
	t: ct.Corner_Table,
	is_on_boundary: bool,
	c: ct.Corner,
) -> (
	gate: ct.Corner,
) {
	gs := c // take any corner as gate_start from the triangle

	if is_on_boundary {
		ge := ct.next_corner(gs)
		// if ge is in fact gate, move gs
		if !ct.vertex_is_on_boundary(t, ct.vertex_of_corner(t, ge)) {
			gs = ct.prev_corner(gs)
		}
		// else is gs correct & no need to do anything
	}

	gate = ct.prev_corner(gs)
	return gate
}
