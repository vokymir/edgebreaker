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
	pos:  [dynamic]Vec3,
	// every vertex-triplet form one face/triangle
	tris: [dynamic]Vertex,
	// opposite corners
	op:   [dynamic]Corner,
	// one (starting) corner for every vertex
	v2c:  [dynamic]Corner,
}

/*
Initialize the Corner_Table structure.

Inputs:
- ct: ptr to uninitialized Corner_Table
- allocator: allocator used for internal structures (dynamic arrays)
- loc: caller location
 */
init :: proc(ct: ^Corner_Table, allocator := context.allocator, loc := #caller_location) {
	ct.pos = make([dynamic]Vec3, allocator, loc)
	ct.tris = make([dynamic]Vertex, allocator, loc)
	ct.op = make([dynamic]Corner, allocator, loc)
	ct.v2c = make([dynamic]Corner, allocator, loc)
}

/*
Destroy the Corner_Table inner structs.

Inputs:
- ct: ptr to initialized Corner_Table
- loc: caller location
*/
destroy :: proc(ct: ^Corner_Table, loc := #caller_location) {
	delete(ct.pos, loc)
	delete(ct.tris, loc)
	delete(ct.op, loc)
	delete(ct.v2c, loc)
}

/****************************** Basic Info Retrieval **************************/

// return some corner belonging to the vertex
v2c :: #force_inline proc(ct: Corner_Table, v: Vertex) -> Corner {
	return ct.v2c[v]
}

// return the vertex of this corner
c2v :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vertex {
	return ct.tris[c]
}

// return index of triangle containing corner c
c2t :: #force_inline proc(c: Corner) -> Triangle {
	if c == INVALID_CORNER {return INVALID_TRIANGLE}
	return Triangle(c / 3)
}

// returns the 3D coordinates of corner c
pos :: #force_inline proc(ct: Corner_Table, c: Corner) -> Vec3 {
	return ct.pos[c2v(ct, c)]
}

/****************************** Basic Traversal *******************************/
// TODO: add basic boundary checks against INVALID_CORNER

// returns the next corner in the same triangle (counter-clockwise)
next :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 1) % 3
}

// returns the previous corner in the same triangle (counter-clockwise)
prev :: #force_inline proc(c: Corner) -> Corner {
	return c / 3 * 3 + (c + 2) % 3
}

// returns the opposite corner across the edge opposite to corner c
op :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	return ct.op[c]
}

// return corner incident with the same vertex, but on the left of c
// (counter-clockwise)
left :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	p := prev(c)
	o := op(ct, p)
	if (o == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return prev(o)
}

// return corner incident with the same vertex, but on the right of c
// (counter-clockwise)
right :: #force_inline proc(ct: Corner_Table, c: Corner) -> Corner {
	n := next(c)
	o := op(ct, n)
	if (o == INVALID_CORNER) {
		return INVALID_CORNER
	}
	return next(o)
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
VC :: proc(ct: Corner_Table, v: Vertex, corners: ^[dynamic]Corner, loc := #caller_location) {
	initial := v2c(ct, v)
	if initial == INVALID_CORNER {return}
	current := initial
	append(corners, current, loc)

	// start traversal of corners to the left
	_left: {
		for {
			current = left(ct, current)
			if current == initial {
				return // done the whole circle around vertex
			}
			if current == INVALID_CORNER {
				break _left // must now go from initial to the right
			}
			append(corners, current, loc)
		}
	}
	// here only if there was invalid corner

	current = initial

	// right
	for {
		current = right(ct, current)
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
border_v :: proc(ct: Corner_Table, v: Vertex) -> bool {
	// the same logic with only small additional allocation, is not worth logic
	// duplication
	_, found := v2c_right_border(ct, v)
	return found
}

/*
   TODO: only return true if corner is bordering??? maybe not, then raname
*/
border_c :: proc(ct: Corner_Table, c: Corner) -> bool {
	_, found := v2c_right_border(ct, c2v(ct, c))
	return found
}

/*
Returns:
- c: corner for which the right_corner() returns INVALID_CORNER, ie right-most
corner (counter-clockwise)
- found: if not on boundary, return false
*/
v2c_right_border :: proc(ct: Corner_Table, v: Vertex) -> (c := INVALID_CORNER, found := false) {
	initial := v2c(ct, v)
	if initial == INVALID_CORNER {return}
	current := initial
	next := current

	// start traversal of corners to the left
	for {
		next = right(ct, current)
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
next_on_border :: proc(ct: Corner_Table, c: Corner) -> (cb := INVALID_CORNER, found := false) {
	if c == INVALID_CORNER {return}
	bf := v2c_right_border(ct, c2v(ct, c)) or_return

	cb = prev(bf)
	found = true
	return
}
