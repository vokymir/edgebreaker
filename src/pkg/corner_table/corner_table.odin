package corner_table

import "core:fmt"
import "core:log"
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
	pos: [dynamic]Vec3,
	// every vertex-triplet form one face/triangle
	c2v: [dynamic]Vertex,
	// opposite corners
	op:  [dynamic]Corner,
	// one (starting) corner for every vertex
	v2c: [dynamic]Corner,
}

/*
Initialize the Corner_Table structure.

Inputs:
- t: ptr to uninitialized Corner_Table
- allocator: allocator used for internal structures (dynamic arrays)
- loc: caller location
 */
init :: proc(t: ^Corner_Table, allocator := context.allocator, loc := #caller_location) {
	t.pos = make([dynamic]Vec3, allocator, loc)
	t.c2v = make([dynamic]Vertex, allocator, loc)
	t.op = make([dynamic]Corner, allocator, loc)
	t.v2c = make([dynamic]Corner, allocator, loc)
}

/*
Destroy the Corner_Table inner structs.

Inputs:
- t: ptr to initialized Corner_Table
- loc: caller location
*/
destroy :: proc(t: ^Corner_Table, loc := #caller_location) {
	delete(t.pos, loc)
	delete(t.c2v, loc)
	delete(t.op, loc)
	delete(t.v2c, loc)
}

/****************************** Basic Info Retrieval **************************/

// return some corner belonging to the vertex
v2c :: #force_inline proc(t: Corner_Table, v: Vertex) -> Corner {
	return t.v2c[v]
}

// return the vertex of this corner
c2v :: #force_inline proc(t: Corner_Table, c: Corner) -> Vertex {
	return t.c2v[c]
}

// return index of triangle containing corner c
c2t :: #force_inline proc(c: Corner) -> Triangle {
	if c < 0 {return INVALID_TRIANGLE}
	return Triangle(c / 3)
}

// returns the 3D coordinates of corner c
pos :: #force_inline proc(t: Corner_Table, c: Corner) -> Vec3 {
	return t.pos[c2v(t, c)]
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
op :: #force_inline proc(t: Corner_Table, c: Corner) -> Corner {
	return t.op[c]
}

// return corner incident with the same vertex, but on the left of c
// (counter-clockwise)
left :: #force_inline proc(t: Corner_Table, c: Corner) -> Corner {
	p := prev(c)
	o := op(t, p)
	if (o < 0) {
		return INVALID_CORNER
	}
	return prev(o)
}

// return corner incident with the same vertex, but on the right of c
// (counter-clockwise)
right :: #force_inline proc(t: Corner_Table, c: Corner) -> Corner {
	n := next(c)
	o := op(t, n)
	if (o < 0) {
		return INVALID_CORNER
	}
	return next(o)
}

/*
Return corner L for corner C.

L --- C --- R
 \  /   \  /
 c.n -- c.p

*/
left_of :: #force_inline proc(t: Corner_Table, c: Corner) -> Corner {
	return op(t, prev(c))
}

/*
Return corner R for corner C.

L --- C --- R
 \  /   \  /
 c.n -- c.p

*/
right_of :: #force_inline proc(t: Corner_Table, c: Corner) -> Corner {
	return op(t, next(c))
}

/****************************** Incidence Queries *****************************/

/*
Vertex-Corners Query: 
Find all corners incident with given vertex. Vertex may be on the boundary.

Inputs:
- t: corner table in which query
- v: vertex to find all corners for
- corners: dynamic array of Corners which this procedure fills with neighbouring
vertices
- loc: caller location
*/
VC :: proc(t: Corner_Table, v: Vertex, corners: ^[dynamic]Corner, loc := #caller_location) {
	initial := v2c(t, v)
	if initial < 0 {return}
	current := initial
	append(corners, current, loc)

	// start traversal of corners to the left
	_left: {
		for {
			current = left(t, current)
			if current == initial {
				return // done the whole circle around vertex
			}
			if current < 0 {
				break _left // must now go from initial to the right
			}
			append(corners, current, loc)
		}
	}
	// here only if there was invalid corner

	current = initial

	// right
	for {
		current = right(t, current)
		if current == initial {
			return
		}
		if current < 0 {
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
border_v :: proc(t: Corner_Table, v: Vertex) -> bool {
	// the same logic with only small additional allocation, is not worth logic
	// duplication
	_, found := v2c_right_border(t, v)
	return found
}

/*
   TODO: only return true if corner is bordering??? maybe not, then raname
*/
border_c :: proc(t: Corner_Table, c: Corner) -> bool {
	_, found := rightmost(t, c)
	return found
}

/*
Returns:
- c: corner for which the right_corner() returns INVALID_CORNER, ie right-most
corner (counter-clockwise)
- found: if not on boundary, return false
*/
v2c_right_border :: proc(t: Corner_Table, v: Vertex) -> (c := INVALID_CORNER, found := false) {
	log.debug("v =", v)
	initial := v2c(t, v)
	log.debug("initial = ", initial)
	if initial < 0 {return}
	current := initial
	next := current

	// start traversal of corners to the left
	for {
		next = right(t, current)
		if next == initial {
			return // full-circle => not boundary
		}
		if next < 0 {
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
- t: corner table
- c: any corner of vertex C

Returns:
- cb: next vertex (CCW), its corner (CB on the schema)
- found: bool
*/
next_on_border :: proc(t: Corner_Table, c: Corner) -> (cb := INVALID_CORNER, found := false) {
	if c < 0 {return}
	bf := rightmost(t, c) or_return

	cb = prev(bf)
	found = true
	return
}

/*
Set all corners around v to have its c2v point to v. The corner c must be
adjacent to vertex v.
*/
set_ring :: proc(t: ^Corner_Table, c: Corner, v: Vertex) {
	log.debug("set ring for c,v:", c, v)

	start, has_border := rightmost(t^, c)
	if !has_border {start = c}

	curr := start
	for {
		t.c2v[curr] = v

		next := left(t^, curr)
		if next == start || next < 0 {break} 	// done full circle
		curr = next
	}
}

/*
Set border vertices to start from initial and increase by one each step.
*/
set_border :: proc(t: ^Corner_Table, c: Corner, initial: Vertex, count: int) {
	log.debug("setting border: c,initial_v", c, initial)
	current := c

	for i in 0 ..< count {
		set_ring(t, current, initial + Vertex(i))

		next, found := next_on_border(t^, current)
		assert(found, "border walk")

		current = next
	}
	r0, _ := rightmost(t^, c)
	r1, _ := rightmost(t^, current)
	assert(
		r0 == r1,
		fmt.tprintf("border walk must be closed, v0 = %v, v1 = %v", t.c2v[r0], t.c2v[r1]),
	)
}

/*
Return the rightmost corner of vertex. If not border, border is false
*/
rightmost :: proc(t: Corner_Table, c: Corner) -> (r: Corner, border: bool) {
	curr := c
	for {
		n := right(t, curr)
		if n < 0 {log.debug("c:", c, "->", curr, "[border]"); return curr, true}
		if n == c {log.debug("c:", c, "[inside]"); return c, false}
		curr = n
	}
}
