package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:slice"
import "core:time"

@(private = "file")
@(disabled = !ODIN_DEBUG)
assert_boundary_consistent :: proc(es: Encoder_State, t: ct.Corner_Table) {
	for i in 0 ..< len(es.next_boundary) {
		c := ct.Corner(i)
		n := es.next_boundary[c]
		if n == ct.INVALID_CORNER {continue}
		assert(es.prev_boundary[n] == c, "Invalid boundary sequence.")
		// c's edge ends at prev(c); the next edge must start there
		assert(
			ct.vertex_of_corner(t, ct.next_corner(n)) == ct.vertex_of_corner(t, ct.prev_corner(c)),
			"Boundary must be continuous.",
		)
	}
}

/***************************** Structs ****************************************/

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

init_es :: proc(
	es: ^Encoder_State,
	n_vertices, n_triangles: int,
	handler := Print_Handler,
	predictor := Predictor_None,
	allocator := context.allocator,
	loc := #caller_location,
) {
	es.vertex_marks = make([]Mark, n_vertices, allocator, loc)
	slice.fill(es.vertex_marks[:], Mark.NOT_VISITED)
	es.next_boundary = make([]ct.Corner, 3 * n_triangles, allocator, loc)
	slice.fill(es.next_boundary[:], ct.INVALID_CORNER)
	es.prev_boundary = make([]ct.Corner, 3 * n_triangles, allocator, loc)
	slice.fill(es.prev_boundary[:], ct.INVALID_CORNER)
	es.gate_stack = make([dynamic]ct.Corner, allocator, loc)

	es.handler = handler
	es.predictor = predictor
	es.allocator = allocator
}

/*
WARN: caller must deallocate handler & predictor
*/
destroy_es :: proc(es: ^Encoder_State, loc := #caller_location) {
	delete(es.vertex_marks, es.allocator, loc)
	delete(es.next_boundary, es.allocator, loc)
	delete(es.prev_boundary, es.allocator, loc)
	delete(es.gate_stack, loc)
}

Operation :: enum {
	C, // create
	L, // left
	R, // right
	S, // split
	E, // end
	BOUNDARY_VERTEX, // emitting boundary vertex
	INITIAL_TRIANGLE,
}

/*
Marks vertices as the algorithm goes through the mesh.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
}

/***************************** Compression ************************************/

compress :: proc {
	compress_ct,
}

/*
Compress mesh represented via corner table and use Encoder_State.handler to
handle (store/send) data.
The encoder_state struct must be initialized before.
*/
@(private)
compress_ct :: proc(t: ct.Corner_Table, es: ^Encoder_State) -> (ok := false) {
	log.debug(t.geometry)
	index, boundary_component, component_found := next_component(es.vertex_marks, t)

	for component_found { 	// for all components
		log.debug("component found on", index)
		//     v                             v      which is handled
		//   /  \     OR this may happen:  /  \     in the if on_boundary{}
		// gs -- ge                      ge -- gs   case
		// as in gate start & gate end
		gs, on_boundary := ct.boundary_corner_of_vertex(t, ct.Vertex(index))
		log.debug("gate is", on_boundary ? "" : "not", "on boundary")
		if on_boundary {
			ge := ct.next_corner(gs)
			if !ct.vertex_is_on_boundary(t, ct.vertex_of_corner(t, ge)) {
				// here ge is in fact v therefore gs is:
				gs = ct.prev_corner(gs)
			}
		} else { 	// take any from the triangle
			gs = ct.corner_of_vertex(t, ct.Vertex(index))
		}
		ge := ct.next_corner(gs)
		gate := ct.next_corner(ge)

		// special case for open-meshes: must find boundary
		if boundary_component {
			log.debug("component has boundary")
			find_all_boundary_edges(es, t, gate) or_return
		}

		gate = initial_triangle(es, t, gate)

		for gate != ct.INVALID_CORNER { 	// for all triangles in 1 component
			assert_boundary_consistent(es^, t)
			log.debug("gate is on corner", gate)
			gs = ct.next_corner(gate)
			ge = ct.prev_corner(gate)

			time.sleep(2 * time.Second) // debug feature

			v_unvisited := es.vertex_marks[ct.vertex_of_corner(t, gate)] == .NOT_VISITED
			v_follows_g := is_next_on_boundary(es^, t, gate, gs)
			v_precedes_g := is_next_on_boundary(es^, t, ge, gate)

			if v_unvisited {
				gate = C(es, t, gate)

			} else if v_follows_g {
				if v_precedes_g {
					gate = E(es, t, gate)
				} else {
					gate = R(es, t, gate)
				}

			} else if v_precedes_g {
				gate = L(es, t, gate)
			} else {
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

	return
}


/*
This is de-facto C, but emits only vertex positions as this is the first
triangle being sent.

   C -- F      v is the corner "under" B, ie D--G is the gate
 /  \ /  \     all other corners/edges will there be referenced
A -- B -- E    by their vertices LETTERS - orientation may be
 \  /x\  /     induced as every triangle is counter clock-wise oriented
  D -- G       

Returns:
- Corner: new gate edge, ie BG
*/
@(private = "file")
initial_triangle :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	dg := v
	gb := ct.next_corner(dg)
	bd := ct.prev_corner(dg)
	D_pos := ct.corner_position(t, gb)
	G_pos := ct.corner_position(t, bd)
	B_pos := ct.corner_position(t, dg)

	// update flags
	es.vertex_marks[ct.vertex_of_corner(t, dg)] = .VISITED
	es.vertex_marks[ct.vertex_of_corner(t, gb)] = .VISITED
	es.vertex_marks[ct.vertex_of_corner(t, bd)] = .VISITED

	bg := ct.opposite_corner(t, ct.next_corner(dg))
	db := ct.opposite_corner(t, ct.prev_corner(dg))

	// rewire boundary edges
	// for bounded mesh
	if ad, bounded_mesh := prev_on_boundary(es^, t, dg); bounded_mesh {
		log.debug("i am in bounded mesh")
		ge, _ := next_on_boundary(es^, t, dg)

		es.next_boundary[ad] = db
		es.next_boundary[db] = bg
		es.next_boundary[bg] = ge

		es.prev_boundary[ge] = bg
		es.prev_boundary[bg] = db
		es.prev_boundary[db] = ad

		es.next_boundary[dg] = ct.INVALID_CORNER
		es.prev_boundary[dg] = ct.INVALID_CORNER

	} else { 	// for closed mesh
		log.debug("i am in closed mesh")
		gd := ct.opposite_corner(t, dg)

		es.next_boundary[gd] = db
		es.next_boundary[db] = bg
		es.next_boundary[bg] = gd

		es.prev_boundary[gd] = bg
		es.prev_boundary[db] = gd
		es.prev_boundary[bg] = db
	}

	emit_step(
		es,
		{op = .INITIAL_TRIANGLE, data = Init_Triangle_Data{gs = D_pos, ge = G_pos, v = B_pos}},
	)

	return bg
}

/*
   C -- F      v is the corner "under" B, ie D--G is the gate
 /  \ /  \     all other corners/edges will there be referenced
A -- B -- E    by their vertices LETTERS - orientation may be
 \  /x\  /     induced as every triangle is counter clock-wise oriented
- D -- G -     
 / \  / \
    H          H completes the last visited triangle

Returns:
- Corner: new gate edge, ie BG
*/
@(private = "file")
C :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	log.debug("C")
	dg := v
	// calculate correction to prediction of next vertex
	H_pos: Vec3
	if v == ct.INVALID_CORNER || ct.opposite_corner(t, dg) == ct.INVALID_CORNER {
		log.debug("cannot get position of H")
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
	ad, _ := prev_on_boundary(es^, t, dg)
	ge, _ := next_on_boundary(es^, t, dg)

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

	emit_step(es, {op = .C, data = C_Data{correction}})

	return bg
}

/*
   C -- F      v is the corner "under" B, ie D--G is the gate
 /  \ /  \     all other corners/edges will there be referenced
A -- B -- E    by their vertices LETTERS - orientation may be
    /x\  / \   induced as every triangle is counter clock-wise oriented
  D -- G -- H  

Returns:
- Corner: new gate edge, ie BG
*/
@(private = "file")
L :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	log.debug("L")
	// find all needed edges
	dg := v
	bd := ct.prev_corner(dg)
	gh, _ := next_on_boundary(es^, t, v)
	ab, _ := prev_on_boundary(es^, t, bd)
	bg := ct.opposite_corner(t, ct.next_corner(dg))

	// rewire: ab -> bg -> gh
	es.prev_boundary[bg] = ab
	es.next_boundary[bg] = gh

	es.prev_boundary[gh] = bg
	es.next_boundary[ab] = bg

	// bd&dg are now not in boundary
	es.prev_boundary[bd] = ct.INVALID_CORNER
	es.next_boundary[bd] = ct.INVALID_CORNER
	es.prev_boundary[dg] = ct.INVALID_CORNER
	es.next_boundary[dg] = ct.INVALID_CORNER

	emit_step(es, {op = .L, data = L_Data{}})

	return bg
}

/*
      C -- F      v is the corner "under" B, ie D--G
    /  \ /  \     all other corners/edges will there be referenced
   A -- B -- E    by their vertices LETTERS - orientation may be
  / \  /x\        induced as every triangle is counter clock-wise oriented
H -- D -- G

Returns:
- Corner: new gate edge, ie DB
*/
@(private = "file")
R :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	log.debug("R")
	// rewire boundary edges
	dg := v
	gb := ct.next_corner(dg)
	hd, _ := prev_on_boundary(es^, t, v)
	be, _ := next_on_boundary(es^, t, gb)
	db := ct.opposite_corner(t, ct.prev_corner(dg))

	// rewire: hd -> db -> be
	es.prev_boundary[db] = hd
	es.next_boundary[db] = be

	es.prev_boundary[be] = db
	es.next_boundary[hd] = db

	// dg&gb are now not in boundary
	es.prev_boundary[dg] = ct.INVALID_CORNER
	es.next_boundary[dg] = ct.INVALID_CORNER
	es.prev_boundary[gb] = ct.INVALID_CORNER
	es.next_boundary[gb] = ct.INVALID_CORNER

	emit_step(es, {op = .R, data = R_Data{}})

	return db
}

/*
      C    F      v is the corner "under" B, ie D--G
    /  \ /  \     all other corners/edges will there be referenced
   A -- B -- E    by their vertices LETTERS - orientation may be
  / \  /x\  / \   induced as every triangle is counter clock-wise oriented
H -- D -- G -- I

Returns:
- Corner: new gate edge, ie BG
*/
@(private = "file")
S :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	log.debug("S")
	// find all needed edges
	dg := v
	// find the boundary edge on the other side of new vertex in O(1)
	// WARN: won't neccessarily work on meshes with holes
	fb := ct.right_corner(t, dg)
	for es.next_boundary[fb] != ct.INVALID_CORNER {
		fb = ct.right_corner(t, dg)
	}

	bc, _ := next_on_boundary(es^, t, fb)

	hd, _ := prev_on_boundary(es^, t, dg)
	gi, _ := next_on_boundary(es^, t, dg)
	db := ct.opposite_corner(t, ct.prev_corner(dg))
	bg := ct.opposite_corner(t, ct.next_corner(dg))

	// rewire the right side (where alg. now continue)
	es.prev_boundary[gi] = bg
	es.next_boundary[bg] = gi
	es.prev_boundary[bg] = fb
	es.next_boundary[fb] = bg

	// rewire the left side
	es.prev_boundary[bc] = db
	es.next_boundary[db] = bc
	es.prev_boundary[db] = hd
	es.next_boundary[hd] = db

	// break the dg edge (hehe, edgebreaker)
	es.next_boundary[dg] = ct.INVALID_CORNER
	es.prev_boundary[dg] = ct.INVALID_CORNER

	// push the left edge on gate_stack
	append(&es.gate_stack, db)

	emit_step(es, {op = .S, data = S_Data{}})
	return bg
}

/*
               v is the corner "under" B, ie D--G
               all other corners/edges will there be referenced
     B         by their vertices LETTERS - orientation may be
    /x\        induced as every triangle is counter clock-wise oriented
  D -- G

*/
@(private = "file")
E :: proc(es: ^Encoder_State, t: ct.Corner_Table, v: ct.Corner) -> ct.Corner {
	log.debug("E")
	dg := v
	gb := ct.next_corner(dg)
	bd := ct.prev_corner(dg)

	es.next_boundary[dg] = ct.INVALID_CORNER
	es.next_boundary[gb] = ct.INVALID_CORNER
	es.next_boundary[bd] = ct.INVALID_CORNER

	es.prev_boundary[dg] = ct.INVALID_CORNER
	es.prev_boundary[gb] = ct.INVALID_CORNER
	es.prev_boundary[bd] = ct.INVALID_CORNER

	emit_step(es, {op = .E, data = E_Data{}})

	new_gate := len(es.gate_stack) > 0 ? pop(&es.gate_stack) : ct.INVALID_CORNER

	return new_gate
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

		es.vertex_marks[ct.vertex_of_corner(t, bd)] = .VISITED
		pos := ct.corner_position(t, bd)

		emit_step(es, {op = .BOUNDARY_VERTEX, data = Boundary_Data{pos}})

		// 2. search one edge to the right (counter-clockwise)
		ie, found := ct.next_boundary_corner(t, gi)
		if !found {return false}

		// 3. store link
		es.prev_boundary[gi] = dg
		es.next_boundary[dg] = gi

		// 4. advance to next edge
		dg = gi
		gi = ie

		if dg == initial {break}
	}

	return true
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

Returns:
- true if c2 is next boundary edge after c1
 */
@(private = "file")
is_next_on_boundary :: proc(es: Encoder_State, t: ct.Corner_Table, c1, c2: ct.Corner) -> bool {
	n := next_on_boundary(es, t, c1) or_return // default bool is false

	return n == c2
}

/*
Find the next (right, counter-clockwise) corner on the current edgebreaker boundary.
*/
@(private = "file")
next_on_boundary :: proc(
	es: Encoder_State,
	t: ct.Corner_Table,
	c: ct.Corner,
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
@(private = "file")
prev_on_boundary :: proc(
	es: Encoder_State,
	t: ct.Corner_Table,
	c: ct.Corner,
) -> (
	prev_c := ct.INVALID_CORNER,
	found := false,
) {
	if c == ct.INVALID_CORNER || c < 0 || int(c) >= len(es.prev_boundary) {
		return
	}

	prev_c = es.prev_boundary[c]
	found = prev_c != ct.INVALID_CORNER
	return
}
