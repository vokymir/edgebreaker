package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:time"

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
init_es :: proc(
	es: ^Encoder_State,
	n_vertices, n_triangles: int,
	handler := Print_Handler,
	predictor := Predictor_None,
	allocator := context.allocator,
	loc := #caller_location,
) {
	es.vertex_marks = make([]Mark, n_vertices, allocator, loc)
	es.next_boundary = make([]ct.Corner, 3 * n_triangles, allocator, loc)
	es.prev_boundary = make([]ct.Corner, 3 * n_triangles, allocator, loc)
	// TODO: maybe do gate_stack, but maybe it is already initialized

	es.handler = handler
	es.predictor = predictor
	es.allocator = allocator
}

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
		log.debug("component found")
		//     v
		//   /  \
		// gs----ge
		// as in gate start & gate end
		gs, on_boundary := ct.boundary_corner_of_vertex(t, ct.Vertex(index))
		if !on_boundary {
			gs = ct.corner_of_vertex(t, ct.Vertex(index))
		}
		log.debug(
			"initial gate start with corner -> vertex:",
			gs,
			"->",
			ct.vertex_of_corner(t, gs),
		)
		ge, gate_exists := ct.next_corner(gs), true
		log.debug("initial gate end with corner -> vertex:", ge, "->", ct.vertex_of_corner(t, ge))

		if !gate_exists {return}

		// special case for open-meshes: must find boundary
		// TODO: extract to special procedure
		if ct.vertex_is_on_boundary(t, ct.Vertex(index)) {
			log.debug("has boundary")
			// find all boundary edges, mark as visited and emit
			// start with the gate end, as specified in paper

			initial := ct.vertex_of_corner(t, ge)
			current := initial
			next, found := ct.next_boundary_vertex(t, current)
			if !found {
				log.debug("invalid mesh")
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

		es.vertex_marks[ct.vertex_of_corner(t, gs)] = .VISITED
		es.vertex_marks[ct.vertex_of_corner(t, ge)] = .VISITED

		for gate_exists {
			v := ct.next_corner(ge)

			time.sleep(2 * time.Second) // debug feature
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
			log.debug(
				"after operation",
				"gs",
				gs,
				"ge",
				ge,
				"gate_exists",
				gate_exists,
				"stack_len",
				len(es.gate_stack),
			)
			// CLERS updates gs, so find ge:
			ge, gate_exists = next_on_boundary(gs, t, es^)
			log.debug("after next_on_boundary", "gs", gs, "ge", ge, "gate_exists", gate_exists)
		} // while the current vertex is in any not visited triangle

		// find another unvisited vertex, ie another mesh
		index, component_found = next_component(t, es.vertex_marks)
	}

	return
}

/*
   C -- F      v is the corner "under" B, ie D--G is the gate
 /  \ /  \     all other corners/edges will there be referenced
A -- B -- E    by their vertices LETTERS - orientation may be
 \  /x\  /     induced as every triangle is counter clock-wise oriented
  D -- G       
   \  /
    H          H completes the last visited triangle
*/
C :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	dg := v
	// calculate correction to prediction of next vertex
	H_pos: Vec3
	if v == ct.INVALID_CORNER {
		H_pos = {0, 0, 0}
	} else {
		H_pos = ct.corner_position(t, ct.opposite_corner(t, dg))
	}
	D_pos := ct.corner_position(t, ct.next_corner(dg))
	G_pos := ct.corner_position(t, ct.prev_corner(dg))

	predicted_pos := es.predictor.predict(D_pos, G_pos, H_pos)
	correction := ct.corner_position(t, dg) - predicted_pos

	// update flags
	es.vertex_marks[ct.vertex_of_corner(t, dg)] = .VISITED

	// rewire boundary edges
	ad, _ := prev_on_boundary(dg, t, es^) // must exist
	ge, _ := next_on_boundary(dg, t, es^) // no check required here

	db := ct.opposite_corner(t, ct.prev_corner(dg))
	bg := ct.opposite_corner(t, ct.next_corner(dg))

	es.next_boundary[ad] = db
	es.next_boundary[db] = bg
	es.next_boundary[bg] = ge

	es.prev_boundary[ge] = bg
	es.prev_boundary[bg] = db
	es.prev_boundary[db] = ad

	es.next_boundary[dg] = ct.INVALID_CORNER
	es.prev_boundary[dg] = ct.INVALID_CORNER

	// calculate the next gate
	new_gate_start := ge

	emit_step(es, {op = .C, data = C_Operation_Data{correction}})

	return new_gate_start
}

L :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	// rewire boundary edges
	prev_b, _ := prev_on_boundary(v, t, es^)
	next_b, _ := next_on_boundary(v, t, es^)
	prev_prev_b, _ := prev_on_boundary(prev_b, t, es^)

	new_b := ct.opposite_corner(t, ct.next_corner(v))

	// prev_b is now not in boundary
	es.next_boundary[prev_b] = ct.INVALID_CORNER
	es.prev_boundary[prev_b] = ct.INVALID_CORNER

	// new boundary is in the middle of prev_prev & next
	es.next_boundary[new_b] = next_b
	es.prev_boundary[new_b] = prev_prev_b

	es.next_boundary[prev_prev_b] = new_b
	es.prev_boundary[next_b] = new_b

	new_gs := ct.left_corner(t, v)
	emit_step(es, {op = .L, data = L_Operation_Data{}})

	return new_gs
}

R :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	// rewire boundary edges
	prev_b, _ := prev_on_boundary(v, t, es^)
	next_b, _ := next_on_boundary(v, t, es^)
	next_next_b, _ := next_on_boundary(next_b, t, es^)

	new_b := ct.opposite_corner(t, ct.prev_corner(v))

	// next_b is now not in boundary
	es.next_boundary[next_b] = ct.INVALID_CORNER
	es.prev_boundary[next_b] = ct.INVALID_CORNER

	// new boundary is in the middle of prev & next_next
	es.next_boundary[new_b] = next_next_b
	es.prev_boundary[new_b] = prev_b

	es.next_boundary[prev_b] = new_b
	es.prev_boundary[next_next_b] = new_b

	new_gs := ct.left_corner(t, v)
	emit_step(es, {op = .R, data = R_Operation_Data{}})

	return new_gs
}

/*
   C    F      v is the corner "under" B, ie D--G
 /  \ /  \     all other corners/edges will there be referenced
A -- B -- E    by their vertices LETTERS - orientation may be
 \  /x\  /     induced as every triangle is counter clock-wise oriented
  D -- G
*/
S :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	// find all needed edges
	dg := v
	// find the boundary edge on the other side of new vertex
	fb, _ := next_on_boundary(dg, t, es^)
	for ct.vertex_of_corner(t, dg) != ct.vertex_of_corner(t, ct.next_corner(fb)) {
		fb, _ = next_on_boundary(fb, t, es^)
	}
	bc, _ := next_on_boundary(fb, t, es^)

	ad, _ := prev_on_boundary(dg, t, es^)
	ge, _ := next_on_boundary(dg, t, es^)
	db := ct.opposite_corner(t, ct.prev_corner(dg))
	bg := ct.opposite_corner(t, ct.next_corner(dg))

	// rewire the right side (where now we continue)
	es.next_boundary[fb] = bg
	es.next_boundary[bg] = ge
	es.prev_boundary[ge] = bg
	es.prev_boundary[bg] = fb

	// rewire the left side
	es.next_boundary[ad] = db
	es.next_boundary[db] = bc
	es.prev_boundary[bc] = db
	es.prev_boundary[db] = ad

	// break the dg edge (hehe, edgebreaker)
	es.next_boundary[dg] = ct.INVALID_CORNER
	es.prev_boundary[dg] = ct.INVALID_CORNER

	// push the left edge on gate_stack
	append(&es.gate_stack, db)

	emit_step(es, {op = .S, data = S_Operation_Data{}})
	return bg
}

E :: proc(v: ct.Corner, t: ct.Corner_Table, es: ^Encoder_State) -> ct.Corner {
	prev_b, _ := prev_on_boundary(v, t, es^)
	next_b, _ := next_on_boundary(v, t, es^)

	es.next_boundary[prev_b] = ct.INVALID_CORNER
	es.next_boundary[v] = ct.INVALID_CORNER
	es.next_boundary[next_b] = ct.INVALID_CORNER

	es.prev_boundary[prev_b] = ct.INVALID_CORNER
	es.prev_boundary[v] = ct.INVALID_CORNER
	es.prev_boundary[next_b] = ct.INVALID_CORNER

	emit_step(es, {op = .E, data = E_Operation_Data{}})

	if len(es.gate_stack) <= 0 {
		return ct.INVALID_CORNER // absolute end of component
	}

	new_gs := pop(&es.gate_stack)

	return new_gs
}

/****************************** Traversal helpers *****************************/

/*
Complexity:
- O(n): For existing open-meshes it might be less than n, for closed meshes it
is always n.
TODO: split into two independent searches, so first it looks for boundaries,
second not for and in total it would be 2n steps, not k*n where k~= # components

Returns:
- index: Index in marks of the first found component. If the component is open,
return index of vertex on boundary. If closed, returns first found index.
*/
next_component :: proc(t: ct.Corner_Table, marks: []Mark) -> (index: int, found: bool) {
	first_closed := max(int)

	log.debug(marks)
	for mark, i in marks {
		if mark == .NOT_VISITED {
			if first_closed > i {
				first_closed = i
			}
			if ct.vertex_is_on_boundary(t, ct.Vertex(i)) {
				log.debug("found on boundary:", i)
				return i, true
			}
		}
	}

	if first_closed > len(marks) {
		log.debug("find nothing")
		return -1, false
	}
	log.debug("found first closed:", first_closed)
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
Find the next (right, anti-clockwise) vertex on the current edgebreaker boundary.
*/
next_on_boundary :: proc(
	c: ct.Corner,
	t: ct.Corner_Table,
	es: Encoder_State,
) -> (
	next_c := ct.INVALID_CORNER,
	found := false,
) {
	if c == ct.INVALID_CORNER || c < 0 || int(c) >= len(es.next_boundary) {
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
