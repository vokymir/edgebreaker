package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:slice"

/***************************** Structs ****************************************/

/*
Stores the state of edgebreaker algorithm during compression.
Is only used with corner table.
*/
Encoder_State :: struct {
	// for destroy
	allocator:          runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:       []Mark,
	// in which step a triangle was discovered (0=never)
	tri_step:           []int,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:         [dynamic]ct.Corner,
	// store S step -> number of hole vertices
	hole_len_of_s:      map[int]int,

	// flag necessary to handle first triangle
	first_in_component: bool,

	// predicts position of next vertex
	predictor:          Predictor,

	// ptr to resulting mesh
	em:                 ^Encoded_Mesh,
}

/*
Initialize Encoder State for Edgebreaker compression with Corner Table.
*/
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

	es.hole_len_of_s = make(map[int]int, allocator, loc)

	es.predictor = predictor
	es.allocator = allocator
}

/*
Destroy internals of Encoder State.
WARN: caller must deallocate predictor (if necessary)
*/
destroy_es :: proc(es: ^Encoder_State, loc := #caller_location) {
	delete(es.vertex_marks, es.allocator, loc)
	delete(es.tri_step, es.allocator, loc)
	delete(es.gate_stack, loc)
	delete(es.hole_len_of_s, loc)
}

/*
Topology entry is necessary for every hole or handle.
It stores two gate corners & hole len.
*/
Topology_Entry :: struct {
	// at which corner was the symbol S emitted
	s_corner:       ct.Corner,
	// at which corner the next triangle would be again the same S triangle if not
	// handled via this entry
	arrival_corner: ct.Corner,
	// if is not hole, hole_len == 0
	hole_len:       int,
}

/*
Store the encoded mesh as a sequence of consecutive CLERS symbols, a list of all
vertices in the order of appeareance and a list of topology entries.

TODO: maybe it will need to store some additional metada, eg. predictor
*/
Encoded_Mesh :: struct {
	symbols:  [dynamic]Operation,
	vertices: [dynamic]Vector3,
	topology: [dynamic]Topology_Entry,
}

/*
Initialize Encoded Mesh. If used with Encoder State (assumed usage) it can
self-attach to it (= set es.em).
*/
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

/*
Destroy the internals of Encoded Mesh.
*/
destroy_em :: proc(em: ^Encoded_Mesh, loc := #caller_location) {
	delete(em.symbols, loc)
	delete(em.vertices, loc)
	delete(em.topology, loc)
}


/***************************** Compression ************************************/

/*
Compress mesh represented via corner table and use Encoder_State.handler to
handle (store/send) data.
The encoder_state struct must be initialized before.

The caller is responsible for freeing returned em.
*/
@(private, require_results)
compress_ct :: proc(es: ^Encoder_State, t: ct.Corner_Table) -> (ok := false, em: ^Encoded_Mesh) {
	log.debug(t.pos)

	em = new(Encoded_Mesh)
	init_em(em, len(t.tris) / 3, len(t.pos), es)

	mark_all_holes(es, t)

	index, has_boundary, found := next_component(es^, t)

	for found {
		log.debug("component found on", index)
		// for asserting eulerity
		sym0 := len(es.em.symbols)
		vert0 := len(es.em.vertices)
		topo0 := len(es.em.topology)

		gate := ct.v2c(t, ct.Vertex(index))
		if has_boundary {
			// here 'gate' is absolutely not a gate, but either gs or ge!
			ge, _ := ct.v2c_right_border(t, ct.Vertex(index))
			gate = gate_from_corner(t, ge)
		}

		compress_component(es, t, gate)

		assert_component_euler(es^, sym0, vert0, topo0, has_boundary)

		index, has_boundary, found = next_component(es^, t, index, has_boundary)
	}

	assert(len(em.symbols) == len(t.tris) / 3, "not one symbol per triangle")
	return true, em
}

/*
Compress one component in mesh.
*/
@(private = "file")
compress_component :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) {
	gate := gate

	initial_triangle(es, t, gate) // handle boundary vertices or just 3 vertices

	for gate != ct.INVALID_CORNER { 	// for all triangles in 1 component
		log.debug("gate is on corner", gate)

		step := len(es.em.symbols)
		check_handles(es, t, gate, step)

		assert(tri_step_eq(es^, gate, 0), "triangle visited twice")
		tri_step(es, gate, step + 1)

		right := ct.op(t, ct.next(gate))
		left := ct.op(t, ct.prev(gate))
		right_done := right == ct.INVALID_CORNER || es.tri_step[ct.c2t(right)] != 0
		left_done := left == ct.INVALID_CORNER || es.tri_step[ct.c2t(left)] != 0

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
			gate = S(es, t, gate, step)
		}
	}
}

/*
Handle the first triangle:
1. boundary triangle: mark&emit all border vertices in correct order
2. closed mesh: mark&emit first two vertices (gs & ge)

set es.first_in_component to true
*/
@(private = "file") // becuase name might be reused in decoding
initial_triangle :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) {
	gs := ct.next(gate)
	ge := ct.prev(gate)

	if ct.border_v(t, ct.c2v(t, gs)) { 	// on border
		l := visit_hole(es, t, ge)

		emit_topology(es, ct.INVALID_CORNER, ct.INVALID_CORNER, l)

	} else {
		mark(es, t, gs, .VISITED)
		mark(es, t, ge, .VISITED)
		emit_vertex(es, ct.pos(t, gs))
		emit_vertex(es, ct.pos(t, ge))
	}

	es.first_in_component = true
}

/*
Handle C operation, the main reason for decomposition is calculation of
prediction and correction.
*/
@(private = "file") // becuase name might be reused in decoding
C :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) -> ct.Corner {
	emit_symbol(es, .C)

	if !es.first_in_component {
		gs_pos := ct.pos(t, ct.next(gate))
		ge_pos := ct.pos(t, ct.prev(gate))
		o_pos := ct.pos(t, ct.op(t, gate))

		pred_input := Predictor_Input {
			gs = gs_pos,
			ge = ge_pos,
			op = o_pos,
		}
		prediction := es.predictor.predict(pred_input)
		correction := ct.pos(t, gate) - prediction

		emit_vertex(es, correction)
	} else { 	// initial triangle must emit absolute position
		emit_vertex(es, ct.pos(t, gate))
		es.first_in_component = false
	}

	mark(es, t, gate, .VISITED)

	right := ct.op(t, ct.next(gate))
	return right
}

/*
Handle S operation, S might be encountering hole or not, but this will work.

Pushes left gate to gate_stack and returns right gate.
*/
@(private = "file") // becuase name might be reused in decoding
S :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner, step: int) -> ct.Corner {

	if is_marked(es^, t, gate, .HOLE) {

		hole_count := visit_hole(es, t, gate)
		if hole_count <= 0 {log.panic("Hole is too short.")}

		es.hole_len_of_s[step] = hole_count
	}

	left := ct.op(t, ct.prev(gate))
	right := ct.op(t, ct.next(gate))

	emit_symbol(es, .S)
	push_gate(es, left)

	return right
}

/*
Handles both holes and handles.

Checks if next triangle will be already encountered S. If so, emits its topology
and therefore saves the information about hole or handle.
*/
@(private = "file") // becuase name might be reused in decoding
check_handles :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner, step: int) {
	// the two non-gate edges: (corner next(gate), k=1) is the right edge,
	// (corner prev(gate), k=2) is the left edge
	sides := [2]struct {
		edge_corner: ct.Corner,
		k:           ct.Corner,
	}{{ct.next(gate), 1}, {ct.prev(gate), 2}}

	for s in sides {
		n := ct.op(t, s.edge_corner)
		if n == ct.INVALID_CORNER {continue} 	// mesh border

		n_step := es.tri_step[ct.c2t(n)]
		if n_step == 0 {continue} 	// not visited yet
		if es.em.symbols[n_step - 1] != .S {continue}

		// reached an S triangle from the side: this can only be its left edge
		s_c := ct.Corner(3 * (n_step - 1) + 2)
		arrival := ct.Corner(3 * step + int(s.k))
		hole_len := es.hole_len_of_s[n_step - 1] // 0 if absent

		emit_topology(es, s_c, arrival, hole_len)
	}

}

/*
Pushes gate to es.gate_stack.
*/
@(private = "file")
push_gate :: #force_inline proc(es: ^Encoder_State, gate: ct.Corner) {
	append(&es.gate_stack, gate)
}

/*
Pop gate stack until unvisited gate is found.
*/
@(private = "file")
pop_unvisited :: #force_inline proc(es: ^Encoder_State) -> ct.Corner {
	for {
		if len(es.gate_stack) == 0 {return ct.INVALID_CORNER}

		candidate := pop(&es.gate_stack)

		if tri_step_eq(es^, candidate, 0) {
			return candidate
		}
	}
}

/****************************** General decomposition *************************/
// all are private to file because are tightly related to the alg

/*
Mark all holes in the whole mesh, in all components, as .HOLE.

Complexity: theta(n)
*/
@(private = "file")
mark_all_holes :: proc(es: ^Encoder_State, t: ct.Corner_Table) {

	for c in t.v2c {

		if ct.border_v(t, ct.c2v(t, c)) {
			mark(es, t, c, .HOLE)
		}
	}
}

/*
Mark all vertices in the hole as visited and return number of those vertices =
length of hole.

Starting from gate-vertex all vertices are marked & emitted.
*/
@(private = "file")
visit_hole :: proc(es: ^Encoder_State, t: ct.Corner_Table, gate: ct.Corner) -> int {
	log.debug(is_marked(es^, t, gate, .HOLE), ct.border_v(t, ct.c2v(t, gate)))

	if !ct.border_v(t, ct.c2v(t, gate)) {return 0}
	log.debug("gate:", gate)

	mark(es, t, gate, .VISITED)
	emit_vertex(es, ct.pos(t, gate))

	initial := ct.c2v(t, gate)
	current := gate
	n := 1 // for the initial gate vertex

	for {
		next, found := ct.next_on_border(t, current)
		if !found {
			log.panic("Cannot find next boundary corner in hole.")
		}

		v := ct.c2v(t, next)
		if v == initial {return n}

		n += 1
		mark(es, t, next, .VISITED)
		emit_vertex(es, ct.pos(t, ct.v2c(t, v)))

		current = next
	}

	return n
}

/******************************* Clarity helpers ******************************/
// all are private to file because they are very small

@(private = "file")
mark :: #force_inline proc(
	es: ^Encoder_State,
	t: ct.Corner_Table,
	c: ct.Corner,
	mark: Mark,
	loc := #caller_location,
) {
	es.vertex_marks[ct.c2v(t, c)] = mark
	log.debug("marked vertex", ct.c2v(t, c), "as", mark, location = loc)
}

@(private = "file")
is_marked :: #force_inline proc(
	es: Encoder_State,
	t: ct.Corner_Table,
	c: ct.Corner,
	mark: Mark,
) -> bool {
	return es.vertex_marks[ct.c2v(t, c)] == mark
}

@(private = "file")
tri_step :: #force_inline proc(
	es: ^Encoder_State,
	gate: ct.Corner,
	step: int,
	loc := #caller_location,
) {
	es.tri_step[ct.c2t(gate)] = step
	log.debug("triangle", ct.c2t(gate), "step set to", step, location = loc)
}

@(private = "file")
tri_step_eq :: #force_inline proc(es: Encoder_State, c: ct.Corner, step: int) -> bool {
	return es.tri_step[ct.c2t(c)] == step
}

@(private = "file")
emit_symbol :: #force_inline proc(es: ^Encoder_State, symbol: Operation, loc := #caller_location) {
	append(&es.em.symbols, symbol)
	log.debug("emitted symbol", symbol, location = loc)
	log.debug(es.vertex_marks, location = loc)
}

@(private = "file")
emit_vertex :: #force_inline proc(
	es: ^Encoder_State,
	pos_or_correction: Vector3,
	loc := #caller_location,
) {
	append(&es.em.vertices, pos_or_correction)
	log.debug("emitted pos/cor", pos_or_correction, location = loc)
}

@(private = "file")
emit_topology :: #force_inline proc(es: ^Encoder_State, s, arr: ct.Corner, l: int) {
	append(&es.em.topology, Topology_Entry{s_corner = s, arrival_corner = arr, hole_len = l})
}

/****************************** Traversal helpers *****************************/
// all are file-private because they are tightly connected to algorithm

/*
Find next component ie next unmarked vertex in marks. 
  if s_f_h is true:
    will prefer boundary vertices and go linear from start (default=0) and only
    after none candidates left go to other vertices
  if not:
    it will go linear from start (default=0) to end

Returns:
- index: Index in marks of the first found component
- found_in_boundary: true if so, might be used in next proc call as s_f_h
- found: there might not be left any
*/
@(private = "file")
next_component :: proc(
	es: Encoder_State,
	t: ct.Corner_Table,
	start := 0,
	search_first_holes := true,
) -> (
	index: int,
	found_in_boundary: bool,
	found: bool,
) {
	start := start
	marks := es.vertex_marks

	log.debug(marks)
	if search_first_holes {
		for mark, i in marks[start:] {
			if mark == .HOLE {
				log.debug("found on border:", i)
				return start + i, true, true
			}
		}
		// not found on boundary, continue search in closed mesh
		log.debug("not found on border")
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
From a corner which should be on border return the corresponding gate corner.

   truth:         case 1    case 2    case 3
                                            
      v              ?         c         ?
    /  \           /  \      /  \      /  \
   gs--ge         ? -- c    ? -- ?    c -- ?
  ~border~

*/
@(private = "file")
gate_from_corner :: proc(t: ct.Corner_Table, c: ct.Corner) -> (gate: ct.Corner) {
	ge := c // assume case1
	gs := ct.prev(ge)
	v := ct.next(ge)

	gs_on_border := ct.border_v(t, ct.c2v(t, gs))
	ge_on_border := ct.border_v(t, ct.c2v(t, ge))
	v_on_border := ct.border_v(t, ct.c2v(t, v))

	switch {
	// case 1
	case gs_on_border && ge_on_border:
		gate = v
	// case 2
	case gs_on_border && v_on_border:
		gate = ge
	// case 3
	case ge_on_border && v_on_border:
		gate = gs
	// corner was not in border triangle
	case:
		return ct.INVALID_CORNER
	}

	return gate
}

/*********************************** Asserts **********************************/

/*
From the Euler equation for triangles mentined in Lewiner et al. paper in
Theroem 2

  chi(S) = |T(S)| - |E(S)| + |V(S)| = 2 - 2 g(S) - b(S)

where
  S ... oriented component
  g ... genus
  b ... # boundary curves

when write simplisticaly

  chi = T - E + V = 2 - 2g - b                                               (1)

we get a few assertable observations:

1) edges & triangles
  every T has 3 E
  E_B (boundary edge) belongs to 1 triangle
  E_I (interal edge) belongs to 2 triangles
  E = E_B + E_I in component

  3T = 2E_I + E_B = 2E - E_B  =>  E = (3T + E_B) / 2                         (2)

  boundary curve is closed loop => #V == #E
  on mainfold: every boundary edge is on EXACTLY one loop

  E_B = B   =>  (3T + B) / 2 = E; E % 2 == 0                                 (3)
  
2) we don't have E
  but using (3) we can substitute in (1)

  chi = T - (3T + B) / 2 + V                                                 (4)

3) handles & holes
  from paper, Proof of Theorem 5:

  (V - chi + 1) - (V - 1) = 2 - chi = 2g + b                                 (5)

  these are the edges that must be explicitely saved, ie #topology entries
  it differs for
  - closed component:     n = 2g         = 2 - chi  (no b needed as b=0)     (6)
  - has boundary:         n = 2g + b - 1 = 1 - chi                           (6)


This procedure asserts multiple equations from this, namely (2) and (6) to test
the validity of the solution.
*/
@(private = "file", disabled = ODIN_DISABLE_ASSERT)
assert_component_euler :: proc(es: Encoder_State, sym0, vert0, topo0: int, has_boundary: bool) {
	T := len(es.em.symbols) - sym0
	V := len(es.em.vertices) - vert0
	topo := es.em.topology[topo0:]

	// count all boundary vertices - from initial border and all holes
	B := 0
	for e in topo {B += e.hole_len}

	assert((3 * T + B) % 2 == 0, "3T + B must be even") // (2)
	E := (3 * T + B) / 2 // (2)
	chi := T - E + V // (1) and (4)

	// due to my TEMPORAL handling of initial boundary as topology entry which is
	// not calculated with in the equations, if such entry was counted it must be
	// subtracted
	n_entries := len(topo) // (6)
	if has_boundary {n_entries -= 1}

	expected := has_boundary ? 1 - chi : 2 - chi // (6)
	assert(n_entries == expected, "topology entries don't match Euler characteristic")
}
