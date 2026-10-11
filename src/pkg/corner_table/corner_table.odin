package corner_table

import "core:fmt"
import "core:math/linalg"

Vec3 :: linalg.Vector3f32

Corner :: distinct int
INVALID_CORNER :: Corner(-1)

Vertex :: distinct int

/*
Represents a triangle mesh in a corner table.
*/
Corner_Table :: struct {
	// geometry: coordinates of each vertex
	g:   [dynamic]Vec3,
	// every vertex-triplet form one face/triangle
	v:   [dynamic]Vertex,
	// opposites
	o:   [dynamic]Corner,
	// one corner for every vertex
	v2c: [dynamic]Corner,
}

/*
Initialize the Corner_Table structure.

Inputs:
- ct: ptr to uninitialized Corner_Table
- allocator: allocator used for internal structures (dynamic arrays)
- loc: caller location
 */
init :: proc(ct: ^Corner_Table, allocator := context.allocator, loc := #caller_location) {
	ct.g = make([dynamic]Vec3, allocator, loc)
	ct.v = make([dynamic]Vertex, allocator, loc)
	ct.o = make([dynamic]Corner, allocator, loc)
	ct.v2c = make([dynamic]Corner, allocator, loc)
}

/*
Destroy the Corner_Table inner structs.

Inputs:
- ct: ptr to initialized Corner_Table
- loc: caller location
*/
destroy :: proc(ct: ^Corner_Table, loc := #caller_location) {
	delete(ct.g, loc)
	delete(ct.v, loc)
	delete(ct.o, loc)
	delete(ct.v2c, loc)
}

// =====
// BASIC INFO RETRIEVAL

// return some corner belonging to the vertex
corner_of_vertex :: #force_inline proc(ct: Corner_Table, v: Vertex) -> Corner {
	return ct.v2c[v]
}

// return the vertex of this corner
vertex_of_corner :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vertex {
	return ct.v[c / 3 + c % 3]
}

// return index of triangle containing corner c
triangle_of_corner :: #force_inline proc(c: Corner) -> int {
	return int(c) / 3
}

// returns the 3D coordinates of corner c
corner_coords :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vec3 {
	return ct.g[c]
}

// =====
// BASIC MOVEMENT

// returns the next corner in the same triangle (counter-clockwise)
corner_next :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 1) % 3
}

// returns the previous corner in the same triangle (counter-clockwise)
corner_prev :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 2) % 3
}

// returns the opposite corner across the edge opposite to corner c
corner_opposite :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	return ct.o[c]
}

// return corner incident with the same vertex, but on the right of c
corner_on_right :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	prev := corner_prev(c)
	op := corner_opposite(ct, prev)
	if (op == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return corner_prev(op)
}

// return corner incident with the same vertex, but on the left of c
corner_on_left :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	next := corner_next(c)
	op := corner_opposite(ct, next)
	if (op == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return corner_next(op)
}

// =====
// INCIDENCE QUERIES

/*
Vertex-Corners Query: 
Find all corners incident with given vertex. Vertex may be on the boundary.

Inputs:
- ct: corner table in which query
- v: vertex to find all corners for
- allocator: where to store discovered corners
- loc: caller location

Returns:
- Slice of corners incident with vertex v. Caller MUST FREE this slice.
*/
@(require_results)
vertex_corners_query :: proc(
	ct: Corner_Table,
	v: Vertex,
	allocator := context.allocator,
	loc := #caller_location,
) -> []Corner {
	// use 6 as average value
	corners := make([dynamic]Corner, 0, 6, allocator, loc)

	initial := corner_of_vertex(ct, v)
	current := initial
	append(&corners, current, loc)

	// start traversal of corners to the right
	right: {
		for current = corner_on_right(ct, current); current != initial; {
			if current == INVALID_CORNER {
				break right
			}
			append(&corners, current, loc)
		}

		// if no INVALID found, it did the whole circle and is done
		return corners[:]
	}
	// here only if there was invalid corner

	current = initial

	// left
	for current = corner_on_left(ct, current); current != INVALID_CORNER; {
		append(&corners, current, loc)
	}

	return corners[:]
}

/*
For testing purposes only.
*/
main :: proc() {
	ct := new(Corner_Table)
	{
		init(ct)
		defer destroy(ct)
		load("lowpoly_tree.obj", ct)

		fmt.print(len(ct.g), "\n")
		fmt.print(len(ct.v), "\n")
		save("tree.obj", ct^)
	}

	{
		init(ct)
		defer destroy(ct)
		load("tetrahedron.obj", ct)

		fmt.print(len(ct.g), "\n")
		fmt.print(len(ct.v), "\n")
		save("tetra.obj", ct^)
	}
}
