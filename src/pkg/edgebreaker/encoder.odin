package edgebreaker

import ct "../corner_table"
import "base:runtime"

C_Operation_Data :: struct {
	vertex_delta: Vec3,
}

L_Operation_Data :: struct {}
R_Operation_Data :: struct {}

S_Operation_Data :: struct {}
E_Operation_Data :: struct {}

// initializing edgebreaker with boundary vertices
B_Operation_Data :: struct {
	vertex_position: Vec3,
}

Operation_Data :: union {
	C_Operation_Data,
	L_Operation_Data,
	E_Operation_Data,
	R_Operation_Data,
	S_Operation_Data,
	B_Operation_Data,
}

Encoder_Event :: struct {
	op:   Operation,
	data: Operation_Data,
}

Encoder_Event_Proc :: #type proc(user_data: rawptr, event: Encoder_Event)

Encoder_Stream_Handler :: struct {
	user_data: rawptr,
	on_event:  Encoder_Event_Proc,
}
// TODO: init/destroy ESH

emit_step :: proc(state: ^Encoder_State, event: Encoder_Event) {
	if state.handler.on_event != nil {
		state.handler.on_event(state.handler.user_data, event)
	}
}

Encoder_State :: struct {
	// for destroy
	allocator:     runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:  []Mark,
	// edge is represented as corner opposite to it in the same triangle
	// if edge is not on the edgebreaker boundary, it is INVALID_CORNER
	next_boundary: []ct.Corner,
	prev_boundary: []ct.Corner,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:    [dynamic]ct.Corner,

	// handle CLERS operations output
	handler:       Encoder_Stream_Handler,

	// predicts position of next vertex
	predictor:     Predictor,
}

// TODO: init/destroy ES

Operation :: enum {
	C, // create
	L, // left
	R, // right
	S, // split
	E, // end
	BOUNDARY_VERTEX, // emitting boundary vertex
}

/*
Used in prepare and in edgebreaker go-through.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
}

/******************************************************************************/

/*
Compress mesh represented via corner table and use Encoder_State.handler to
handle (store/send) data.
The encoder_state struct must be initialized before.
*/
compress_ct :: proc(t: ct.Corner_Table, es: ^Encoder_State) -> (ok := false) {
	// while there are any unvisited vertices
	//   get the lowest unvisited vertex
	//   while the current vertex has right neighbour, take them as gate edge
	//     inspect that gate edge
	//     perform CLERS operation, ie maybe modifying current vertex in the process
	//     & marking vertices and/or triangles

	index, component_found := next_component(t, es.vertex_marks)

	for component_found {
		//     v
		//   /  \
		// gs----ge
		// as in gate start & gate end
		gs, _ := ct.boundary_corner_of_vertex(t, ct.Vertex(index))
		ge, gate_exists := ct.next_corner(gs), true

		if !gate_exists {return}

		// special case for open-meshes: must find boundary
		// TODO: extract to special procedure
		if ct.vertex_is_on_boundary(t, ct.Vertex(index)) {
			// find all boundary edges, mark as visited and emit
			// start with the gate end, as specified in paper

			initial := ct.vertex_of_corner(t, ge)
			current := initial
			next, found := ct.next_boundary_vertex(t, current)
			if !found {
				return //invalid mesh
			}

			for current != initial { 	// start on ge, end just before doing ge again

				// mark
				es.vertex_marks[current] = .VISITED
				pos := ct.corner_position(t, ct.corner_of_vertex(t, current))

				// emit
				emit_step(es, {op = .BOUNDARY_VERTEX, data = B_Operation_Data{pos}})

				// store in lists
				current_b := third_corner(current, next, t)

				// (need to advance here)
				current = next
				next, found = ct.next_boundary_vertex(t, next)
				if !found {
					return //invalid mesh
				}
				// continur storing in lists
				next_b := third_corner(current, next, t)

				es.next_boundary[current_b] = next_b
				es.prev_boundary[next_b] = current_b
			}
		}

		for gate_exists {
			v := ct.next_corner(ge)

			if es.vertex_marks[ct.vertex_of_corner(t, v)] == .NOT_VISITED {
				gs = C(v, t, es)
			} else if is_next_on_boundary(v, ge, t, es^) {
				if is_next_on_boundary(ge, v, t, es^) {
					gs = E(v, t, es)
				} else {
					gs = R(v, t, es)
				}
			} else if is_next_on_boundary(v, gs, t, es^) {
				gs = L(v, t, es)
			} else {
				gs = S(v, t, es)
			}
			// CLERS updates gs, so find ge:
			ge, gate_exists = next_on_boundary(gs, t, es^)
		} // while the current vertex is in any not visited triangle

		// find another unvisited vertex, ie another mesh
		index, component_found = next_component(t, es.vertex_marks)
	}

	return
}

C :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	// calculate correction to prediction of next vertex
	o_pos := ct.corner_position(t, ct.opposite_corner(t, v))
	if v == ct.INVALID_CORNER {
		o_pos = {0, 0, 0}
	}
	gs_pos := ct.corner_position(t, ct.next_corner(v))
	ge_pos := ct.corner_position(t, ct.prev_corner(v))

	predicted_pos := es.predictor.predict(gs_pos, ge_pos, o_pos)
	correction := ct.corner_position(t, v) - predicted_pos

	// update flags
	es.vertex_marks[ct.vertex_of_corner(t, v)] = .VISITED

	// rewire boundary edges
	prev_b, _ := prev_on_boundary(v, t, es^) // must exist
	next_b, _ := next_on_boundary(v, t, es^) // no check required here

	new_left_b := ct.opposite_corner(t, ct.prev_corner(v))
	new_right_b := ct.opposite_corner(t, ct.next_corner(v))

	es.next_boundary[prev_b] = new_left_b
	es.next_boundary[new_left_b] = new_right_b
	es.next_boundary[new_right_b] = next_b

	es.prev_boundary[next_b] = new_right_b
	es.prev_boundary[new_right_b] = new_left_b
	es.prev_boundary[new_left_b] = prev_b

	// calculate the next gate
	new_gs := ct.left_corner(t, v)

	emit_step(es, {op = .C, data = C_Operation_Data{correction}})

	return new_gs
}

L :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	return -1
}

E :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	return -1
}

R :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	return -1
}

S :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	return -1
}

/****************************** Traversal helpers *****************************/

/*
Complexity:
- O(n): For existing open-meshes it might be less than n, for closed meshes it
is always n.

Returns:
- index: Index in marks of the first found component. If the component is open,
return index of vertex on boundary. If closed, returns first found index.
*/
next_component :: proc(t: ct.Corner_Table, marks: []Mark) -> (index: int, found: bool) {
	first_closed := max(int)

	for mark, i in marks[:] {
		if mark == .NOT_VISITED {
			if first_closed > i {
				first_closed = i
			}
			if ct.vertex_is_on_boundary(t, ct.Vertex(i)) {
				return i, true
			}
		}
	}

	if first_closed > len(marks) {
		return -1, false
	}
	return first_closed, true
}

// find third vertex for given vertices, but return it as a corner
third_corner :: proc(v1, v2: ct.Vertex, t: ct.Corner_Table) -> ct.Corner {
	c := ct.corner_of_vertex(t, v1)
	// if on boundary, start most left
	if ct.vertex_is_on_boundary(t, v1) {
		for l := ct.left_corner(t, c); l != ct.INVALID_CORNER; c = l {
			l = ct.left_corner(t, c)
		}
	}

	// find the correct corner in triangle
	for ct.vertex_of_corner(t, ct.next_corner(c)) != v2 {
		c = ct.right_corner(t, c)
	}

	// return the third corner in that triangle
	return ct.prev_corner(c)
}

is_next_on_boundary :: proc(c1, c2: ct.Corner, t: ct.Corner_Table, es: Encoder_State) -> bool {
	n := next_on_boundary(c1, t, es) or_return // default bool is false

	return n == c2
}

/*
Find the next (right) vertex on the current edgebreaker boundary.
MUST handle init case = all vertices are unvisited, so must choose one from that
*/
next_on_boundary :: proc(
	c: ct.Corner,
	t: ct.Corner_Table,
	es: Encoder_State,
) -> (
	next_c := ct.INVALID_CORNER,
	found := false,
) {
	if c < 0 || int(c) >= len(es.next_boundary) {
		return
	}

	next_c = es.next_boundary[c]
	found = next_c != ct.INVALID_CORNER
	return
}
prev_on_boundary :: proc(
	c: ct.Corner,
	t: ct.Corner_Table,
	es: Encoder_State,
) -> (
	prev_c := ct.INVALID_CORNER,
	found := false,
) {
	if c < 0 || int(c) >= len(es.prev_boundary) {
		return
	}

	prev_c = es.prev_boundary[c]
	found = prev_c != ct.INVALID_CORNER
	return
}
