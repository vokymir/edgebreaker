package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:slice"

/*
Data used during encoding.
*/
Encoding_Data :: struct {
	// for destroy
	allocator:     runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:  []Mark,
	// edge is represented as corner opposite to it in the same triangle
	// if edge is not on the edgebreaker boundary, it is INVALID_CORNER
	next_boundary: []ct.Corner,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:    [dynamic]ct.Corner,

	// least sufficient mesh info for reconstruction
	// maybe rather use small array - for simple pushing
	history:       []Operation, // as many T as many operations
	vertices:      []ct.Vec3, // just in different order than in ct.geometry
	// maybe proc() for predictor, or its number
}

init_ed :: proc(
	ed: ^Encoding_Data,
	n_verts, n_triangles: int,
	allocator := context.allocator,
	loc := #caller_location,
) {
	ed.allocator = allocator

	ed.vertex_marks = make([]Mark, n_verts, allocator, loc)
	slice.fill(ed.vertex_marks[:], Mark.NOT_VISITED)
	ed.next_boundary = make([]ct.Corner, n_verts * 3, allocator, loc)
	slice.fill(ed.next_boundary[:], ct.INVALID_CORNER)
	ed.gate_stack = make([dynamic]ct.Corner, allocator, loc)

	ed.history = make([]Operation, n_triangles, allocator, loc)
	ed.vertices = make([]ct.Vec3, n_verts, allocator, loc)
}

destroy_ed :: proc(ed: ^Encoding_Data, loc := #caller_location) {
	delete(ed.vertex_marks, ed.allocator, loc)
	delete(ed.next_boundary, ed.allocator, loc)
	delete(ed.gate_stack, loc)

	delete(ed.history, ed.allocator, loc)
	delete(ed.vertices, ed.allocator, loc)
}

Operation :: enum {
	C, // create
	L, // left
	R, // right
	S, // start
	E, // end
}

/*
Used in prepare (only not/visited) and in edgebreaker go-through.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
}

/******************************************************************************/

/*
Compress mesh represented via corner table and store result in data struct.
The encoding data struct must be initialized before.
*/
compress_ct :: proc(t: ct.Corner_Table, ed: ^Encoding_Data) -> (ok := false) {
	// while there are any unvisited vertices
	//   get the lowest unvisited vertex
	//   while the current vertex has right neighbour, take them as gate edge
	//     inspect that gate edge
	//     perform CLERS operation, ie maybe modifying current vertex in the process
	//     & marking vertices and/or triangles

	index, component_found := slice.linear_search(ed.vertex_marks[:], Mark.NOT_VISITED)

	for component_found {
		//     v
		//   /  \
		// gs----ge
		// as in gate start & gate end
		gs := ct.corner_of_vertex(t, ct.Vertex(index))
		ge, gate_exists := ct.next_corner(gs), true

		for gate_exists {
			v := ct.next_corner(ge)

			if ed.vertex_marks[ct.vertex_of_corner(t, v)] == .NOT_VISITED {
				C(v, t, ed)
			} else if is_next_on_boundary(v, ge, t, ed^) {
				if is_next_on_boundary(ge, v, t, ed^) {
					E(v, t, ed)
				} else {
					R(v, t, ed)
				}
			} else if is_next_on_boundary(v, gs, t, ed^) {
				L(v, t, ed)
			} else {
				S(v, t, ed)
			}
			// CLERS updates current, so find next:
			ge, gate_exists = next_on_boundary(gs, t, ed^)
		} // while the current vertex is in any not visited triangle

		// find another unvisited vertex, ie another mesh
		index, component_found = slice.linear_search(ed.vertex_marks[index:], Mark.NOT_VISITED)
	}
	return
}

C :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
L :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
E :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
R :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
S :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
M_hole :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}
M_handle :: proc(v: ct.Corner, t: ct.Corner_Table, ed: ^Encoding_Data) {}

/****************************** Traversal helpers *****************************/

// find third vertex for given "edge"
// NOW NOT USED BECAUSE CORNERS ARE NOW USED
// third_vertex :: proc(v1, v2: ct.Vertex, t: ct.Corner_Table) -> ct.Vertex {
// 	c := ct.corner_of_vertex(t, v1)
// 	// if on boundary, start most left
// 	if ct.vertex_is_on_boundary(t, v1) {
// 		for l := ct.left_corner(t, c); l != ct.INVALID_CORNER; c = l {
// 			l = ct.left_corner(t, c)
// 		}
// 	}
//
// 	// find the correct corner in triangle
// 	for ct.vertex_of_corner(t, ct.next_corner(c)) != v2 {
// 		c = ct.right_corner(t, c)
// 	}
//
// 	return ct.vertex_of_corner(t, ct.prev_corner(c))
// }

is_next_on_boundary :: proc(c1, c2: ct.Corner, t: ct.Corner_Table, ed: Encoding_Data) -> bool {
	n := next_on_boundary(c1, t, ed) or_return // default bool is false

	return n == c2
}

/*
Find the next (right) vertex on the current edgebreaker boundary.
MUST handle init case = all vertices are unvisited, so must choose one from that
*/
// TODO: maybe also left variant ???
next_on_boundary :: proc(
	c: ct.Corner,
	t: ct.Corner_Table,
	ed: Encoding_Data,
) -> (
	next_c := ct.INVALID_CORNER,
	found := false,
) {
	if c < 0 || int(c) >= len(ed.next_boundary) {
		return
	}

	next_c = ed.next_boundary[c]
	found = next_c != ct.INVALID_CORNER
	return
}
