package corner_table

Vec3 :: [3]f32

Corner :: distinct int
INVALID_CORNER :: Corner(-1)

Vertex :: distinct int
INVALID_VERTEX :: Vertex(-1)

Triangle :: distinct int
INVALID_TRIANGLE :: Triangle(-1)

/*
Represents a triangle mesh in a corner table.
*/
Corner_Table :: struct {
	// geometry: coordinates of each vertex
	geometry:       [dynamic]Vec3,
	// every vertex-triplet form one face/triangle
	vertices:       [dynamic]Vertex,
	// opposite corners
	opposites:      [dynamic]Corner,
	// one (starting) corner for every vertex
	vertex_corners: [dynamic]Corner,
}

/*
Initialize the Corner_Table structure.

Inputs:
- ct: ptr to uninitialized Corner_Table
- allocator: allocator used for internal structures (dynamic arrays)
- loc: caller location
 */
init :: proc(ct: ^Corner_Table, allocator := context.allocator, loc := #caller_location) {
	ct.geometry = make([dynamic]Vec3, allocator, loc)
	ct.vertices = make([dynamic]Vertex, allocator, loc)
	ct.opposites = make([dynamic]Corner, allocator, loc)
	ct.vertex_corners = make([dynamic]Corner, allocator, loc)
}

/*
Destroy the Corner_Table inner structs.

Inputs:
- ct: ptr to initialized Corner_Table
- loc: caller location
*/
destroy :: proc(ct: ^Corner_Table, loc := #caller_location) {
	delete(ct.geometry, loc)
	delete(ct.vertices, loc)
	delete(ct.opposites, loc)
	delete(ct.vertex_corners, loc)
}

/****************************** Basic Info Retrieval **************************/

// return some corner belonging to the vertex
corner_of_vertex :: #force_inline proc(ct: Corner_Table, v: Vertex) -> Corner {
	return ct.vertex_corners[v]
}

// return the vertex of this corner
vertex_of_corner :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vertex {
	return ct.vertices[c]
}

// return index of triangle containing corner c
triangle_of_corner :: #force_inline proc(c: Corner) -> Triangle {
	if c == INVALID_CORNER {return INVALID_TRIANGLE}
	return Triangle(c / 3)
}

// returns the 3D coordinates of corner c
corner_position :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vec3 {
	return ct.geometry[vertex_of_corner(ct, c)]
}

/****************************** Basic Traversal *******************************/

// returns the next corner in the same triangle (counter-clockwise)
next_corner :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 1) % 3
}

// returns the previous corner in the same triangle (counter-clockwise)
prev_corner :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 2) % 3
}

// returns the opposite corner across the edge opposite to corner c
opposite_corner :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	return ct.opposites[c]
}

// return corner incident with the same vertex, but on the left of c
// (counter-clockwise)
left_corner :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	prev := prev_corner(c)
	op := opposite_corner(ct, prev)
	if (op == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return prev_corner(op)
}

// return corner incident with the same vertex, but on the right of c
// (counter-clockwise)
right_corner :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	next := next_corner(c)
	op := opposite_corner(ct, next)
	if (op == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return next_corner(op)
}

/****************************** Incidence Queries *****************************/

/*
Vertex-Corners Query: 
Find all corners incident with given vertex. Vertex may be on the boundary.

Inputs:
- ct: corner table in which query
- v: vertex to find all corners for
- corners: dynamic array of Corners which this procedure fills with neighbouring
vertices
- loc: caller location
*/
vertex_corners_query :: proc(
	ct: Corner_Table,
	v: Vertex,
	corners: ^[dynamic]Corner,
	loc := #caller_location,
) {
	initial := corner_of_vertex(ct, v)
	if initial == INVALID_CORNER {return}
	current := initial
	append(corners, current, loc)

	// start traversal of corners to the right
	left: {
		for {
			current = left_corner(ct, current)
			if current == initial {
				return // done the whole circle around vertex
			}
			if current == INVALID_CORNER {
				break left // must now go from initial to the right
			}
			append(corners, current, loc)
		}
	}
	// here only if there was invalid corner

	current = initial

	// right
	for {
		current = right_corner(ct, current)
		if current == initial {
			return
		}
		if current == INVALID_CORNER {
			break
		}
		append(corners, current, loc)
	}

	return
}

/*
Is useful for edgebreaker pre-processing & finding the initial boundary and
all holes.
*/
vertex_is_on_boundary :: proc(ct: Corner_Table, v: Vertex) -> bool {
	// the same logic with only small additional allocation, is not worth logic
	// duplication
	_, found := rightmost_boundary_corner_of_vertex(ct, v)
	return found
}

// TODO: update to not need vertex at all...
c_on_boundary :: proc(ct: Corner_Table, c: Corner) -> bool {
	_, found := rightmost_boundary_corner_of_vertex(ct, vertex_of_corner(ct, c))
	return found
}

/*
Returns:
- c: corner for which the right_corner() returns INVALID_CORNER, ie right-most
corner (counter-clockwise)
- found: if not on boundary, return false
*/
rightmost_boundary_corner_of_vertex :: proc(
	ct: Corner_Table,
	v: Vertex,
) -> (
	c := INVALID_CORNER,
	found := false,
) {
	initial := corner_of_vertex(ct, v)
	if initial == INVALID_CORNER {return}
	current := initial
	next := current

	// start traversal of corners to the left
	for {
		next = right_corner(ct, current)
		if next == initial {
			return // full-circle => not boundary
		}
		if next == INVALID_CORNER {
			return current, true
		}
		current = next
	}
}


/*

 ~ nothing ~
 D -- C -- F
  \  / \  /  =>   search direction
   A -- B 
    \  /
     E

Inputs:
- ct: corner table
- c: any corner of vertex C

Returns:
- cb: next vertex (CCW), its corner (CB on the schema)
- found: bool
*/
next_boundary_corner :: proc(
	ct: Corner_Table,
	c: Corner,
) -> (
	cb := INVALID_CORNER,
	found := false,
) {
	if c == INVALID_CORNER {return}
	bf := rightmost_boundary_corner_of_vertex(ct, vertex_of_corner(ct, c)) or_return

	cb = prev_corner(bf)
	found = true
	return
}
