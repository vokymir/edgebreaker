#+private file
package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:slice"

/******************************* TYPES ****************************************/

next :: ct.next
prev :: ct.prev
right_edge :: ct.next
left_edge :: ct.prev

// those assume tip given
gate_start :: ct.next
gate_end :: ct.prev

/* 
Temporary values for connectivity pass.
Must not collide with ct.INVALID_CORNER.
*/
FREE_LEFT :: ct.Corner(-10)
FREE_RIGHT :: ct.Corner(-20)

/******************************* STRUCTS **************************************/

/*
Hole already found by S but the vertices not known yet.
*/
Pending_Hole :: struct {
	tip:   ct.Corner, // tip of S triangle
	first: ct.Vertex, // id of the first (tip) hole vertex
	len:   int, // #verts in hole
}

Decoder_State :: struct {
	t:             ^ct.Corner_Table,
	symbols:       []Operation,
	vertices:      []Vector3,
	allocator:     runtime.Allocator,

	// lookups prepared from topology
	holes:         map[ct.Corner]int, // map tip corner -> hole len
	glues:         map[ct.Corner]ct.Corner, // map corner -> corner (arrival to S-left)

	// both passes
	gate_stack:    [dynamic]Gate,

	// connectivity pass
	sym_pos:       int,
	last_tri:      ct.Triangle,
	last_vertex:   ct.Vertex,
	pending_holes: [dynamic]Pending_Hole,

	// geometry pass
	vtx_pos:       int,
	vertex_done:   []bool,
	tri_done:      []bool,
	vtx_codec:     Vertex_Codec,
}

init_ds :: proc(
	ds: ^Decoder_State,
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	n_triangles := len(em.symbols)
	n_vertices := len(em.vertices)

	prepare_corner_table(t, n_vertices, n_triangles, loc)

	ds^ = Decoder_State {
		t             = t,
		symbols       = em.symbols[:],
		vertices      = em.vertices[:],
		allocator     = allocator,
		//
		holes         = make(map[ct.Corner]int, allocator, loc),
		glues         = make(map[ct.Corner]ct.Corner, allocator, loc),
		//
		gate_stack    = make([dynamic]Gate, allocator, loc),
		//
		sym_pos       = 0,
		last_tri      = ct.INVALID_TRIANGLE,
		last_vertex   = ct.INVALID_VERTEX,
		pending_holes = make([dynamic]Pending_Hole, allocator, loc),
		//
		vtx_pos       = 0,
		vertex_done   = make([]bool, n_vertices, allocator, loc),
		tri_done      = make([]bool, n_triangles, allocator, loc),
		vtx_codec     = vertex_codec_of(em.vertex_codec),
	}

	prepare_topology_lookups(ds, em.topology[:])
}

/*
Make some insides of corner table adequately sized.
*/
prepare_corner_table :: proc(
	t: ^ct.Corner_Table,
	n_vertices, n_triangles: int,
	loc := #caller_location,
) {
	assert(len(t.pos) == 0, "not empty corner table")
	assert(len(t.c2v) == 0, "not empty corner table")
	assert(len(t.op) == 0, "not empty corner table")
	assert(len(t.v2c) == 0, "not empty corner table")

	resize(&t.pos, n_vertices, loc)
	resize(&t.c2v, 3 * n_triangles, loc)
	resize(&t.op, 3 * n_triangles, loc)
	slice.fill(t.c2v[:], ct.INVALID_VERTEX)
	slice.fill(t.op[:], ct.INVALID_CORNER)
}

/*
Transform topology entries into maps for O(1) lookup time.
*/
prepare_topology_lookups :: proc(ds: ^Decoder_State, topology: []Topology_Entry) {
	for top in topology {
		s_tip := ct.Corner(3 * top.s_step)
		arrival_tip := ct.Corner(3 * top.arrival_step)
		s_corner := side_corner(s_tip, .LEFT) // always left side
		arrival_corner := side_corner(arrival_tip, top.arrival_side)

		ds.glues[arrival_corner] = s_corner

		if top.hole_len > 0 {
			ds.holes[s_tip] = top.hole_len
		}
	}
}

destroy_ds :: proc(ds: ^Decoder_State, loc := #caller_location) {
	delete(ds.holes, loc)
	delete(ds.glues, loc)
	delete(ds.gate_stack, loc)
	delete(ds.pending_holes, loc)
	delete(ds.vertex_done, ds.allocator, loc)
	delete(ds.tri_done, ds.allocator, loc)
}

/********************************** ENTRY *************************************/

@(private)
decode_wrap_and_zip_ct :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	ds: Decoder_State
	init_ds(&ds, em, t, allocator, loc)
	defer destroy_ds(&ds, loc)

	// store component starts
	starts := make([dynamic]ct.Corner, 0, len(em.components), allocator, loc)
	defer delete(starts, loc)

	// pass 1: connectivity
	for comp in em.components {
		append(&starts, decode_component_connectivity(&ds, comp))
	}
	assert(ds.sym_pos == len(ds.symbols), "unused symbols")
	assert(int(ds.last_vertex + 1) == len(em.vertices), "missing vertex")

	finalize_corner_table(&ds, loc)
	assert_corner_table_consistent(t^)

	// pass 2: geometry
	for comp, i in em.components {
		decode_component_geometry(&ds, starts[i], comp)
	}
	assert(ds.vtx_pos == len(ds.vertices), "unused vertices")
}

/******************************* PASS 1: CONNECTIVITY *************************/

/*
Returns:
- tip corner of first triangle
*/
decode_component_connectivity :: proc(ds: ^Decoder_State, comp: Component_Info) -> ct.Corner {
	start, first_vertex := begin_component(ds, comp)

	decode_component_triangles(ds, start)
	finish_component(ds, start, first_vertex, comp)

	return start
}

/*
Reserve vertices for initial triangle and maybe outer boundary.

Returns:
- start: tip of first triangle
- first_vertex: id of gs (1st component vertex, absolute position)
*/
begin_component :: proc(
	ds: ^Decoder_State,
	comp: Component_Info,
) -> (
	start: ct.Corner,
	first_vertex: ct.Vertex,
) {
	log.debug("begin component", comp)
	start = peek_next_tip(ds^)

	if comp.outer_boundary > 0 { 	// BOUNDARY COMPONENT
		first_vertex = begin_boundary_component(ds, start, comp.outer_boundary)
	} else { 	// CLOSED COMPONENT
		first_vertex = begin_closed_component(ds, start)
	}

	return start, first_vertex
}

/*
reserve border vertex ids, process gs,ge
the assigning of vertex ids is done in finish_component
*/
begin_boundary_component :: proc(ds: ^Decoder_State, tip: ct.Corner, n_border: int) -> ct.Vertex {
	first := reserve_vertex_ids(ds, n_border)

	ds.t.c2v[gate_start(tip)] = first
	ds.t.c2v[gate_end(tip)] = first + ct.Vertex(n_border - 1)

	return first
}

begin_closed_component :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Vertex {
	first := reserve_vertex_ids(ds, 2)

	ds.t.c2v[gate_start(tip)] = first
	ds.t.c2v[gate_end(tip)] = first + 1
	ds.t.op[tip] = FREE_LEFT

	return first
}

/*
Main connectivity loop, iterates over triangles.
*/
decode_component_triangles :: proc(ds: ^Decoder_State, start: ct.Corner) {
	tip := new_triangle(ds) // initial triangle
	assert(tip == start, "component must start on the next free triangle")

	for {
		// glue depends on triangle, not the symbol
		glue_triangle(ds, tip)

		symbol := read_symbol(ds)
		edge := apply_symbol(ds, tip, symbol)
		if edge == ct.INVALID_CORNER {return} 	// finished component

		assert(!is_linked(ds.t.op[edge]), "enc/dec mismatch: next gate is already linked")
		tip = attach_triangle(ds, edge)
	}
}

/*
Create new triangle. It is attached to "edge".

Returns:
- tip: tip of the new triangle
*/
attach_triangle :: proc(ds: ^Decoder_State, edge: ct.Corner) -> (tip: ct.Corner) {
	t := ds.t
	tip = new_triangle(ds)

	t.op[edge] = tip
	t.op[tip] = edge

	t.c2v[gate_start(tip)] = t.c2v[prev(edge)]
	t.c2v[gate_end(tip)] = t.c2v[next(edge)]

	return tip
}

/********************************* CLERS **************************************/

/*
Returns:
- edge: corner which the next triangle should be attached to
  INVALID_CORNER = component is finished
*/
apply_symbol :: proc(ds: ^Decoder_State, tip: ct.Corner, symbol: Operation) -> (edge: ct.Corner) {
	switch symbol {
	case .C:
		edge = apply_C(ds, tip)
	case .L:
		edge = apply_L(ds, tip)
	case .R:
		edge = apply_R(ds, tip)
	case .S:
		edge = apply_S(ds, tip)
	case .E:
		edge = apply_E(ds, tip)
	}
	return edge
}

// new vertex, left is open, return right
apply_C :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Corner {
	set_free(ds.t, left_edge(tip), FREE_LEFT)
	ds.t.c2v[tip] = reserve_vertex_id(ds)
	return right_edge(tip)
}
// left triangle already exists, close it (zip), continue right
apply_L :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Corner {
	set_free(ds.t, left_edge(tip), FREE_RIGHT)
	zip_if_free_right(ds, left_edge(tip))
	return right_edge(tip)
}
// right triangle already exists, continue left
apply_R :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Corner {
	set_free(ds.t, right_edge(tip), FREE_RIGHT)
	return left_edge(tip)
}
// split: push left, return right
apply_S :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Corner {
	push_gate(ds, left_edge(tip))
	return right_edge(tip)
}
// end: close sides, zip, pop gate_stack
apply_E :: proc(ds: ^Decoder_State, tip: ct.Corner) -> ct.Corner {
	set_free(ds.t, right_edge(tip), FREE_RIGHT)
	set_free(ds.t, left_edge(tip), FREE_RIGHT)
	zip_if_free_right(ds, left_edge(tip))
	return pop_unlinked_gate(ds)
}

/*
Mark edge as free ONLY if it isn't already linked.
*/
set_free :: proc(t: ^ct.Corner_Table, edge, mark: ct.Corner) {
	if !is_linked(t.op[edge]) {t.op[edge] = mark}
}

/****************************** HOLES & HANDLES *******************************/

/*
Check everything:
a) is a hole? if so, reserve
b) is arrival? if so, link
*/
glue_triangle :: proc(ds: ^Decoder_State, tip: ct.Corner) {
	reserve_hole_vertices(ds, tip)
	glue_side(ds, side_corner(tip, .RIGHT))
	glue_side(ds, side_corner(tip, .LEFT))
}

/*
If tip is on hole: reserve vertices (assigned in finish_component)
*/
reserve_hole_vertices :: proc(ds: ^Decoder_State, tip: ct.Corner) {
	n, is_hole := ds.holes[tip]
	if !is_hole {return}

	first := reserve_vertex_ids(ds, n)
	ds.t.c2v[tip] = first
	append(&ds.pending_holes, Pending_Hole{tip = tip, first = first, len = n})
}

/*
If corner is arrival corner, link it.
*/
glue_side :: proc(ds: ^Decoder_State, corner: ct.Corner) {
	t := ds.t

	s_left, is_arrival := ds.glues[corner]
	if !is_arrival {return}

	t.op[corner] = s_left
	t.op[s_left] = corner

	unify_vertices(t, next(corner), prev(s_left))
	unify_vertices(t, prev(corner), next(s_left))
}

/*
Corners (at least one) were just assigned the same vertex. Give it to the whole
ring.
*/
unify_vertices :: proc(t: ^ct.Corner_Table, a, b: ct.Corner) {
	va, vb := t.c2v[a], t.c2v[b]
	if va == ct.INVALID_VERTEX && vb == ct.INVALID_VERTEX {return}

	valid_case := va == vb || va == ct.INVALID_VERTEX || vb == ct.INVALID_VERTEX
	assert(valid_case, "glued corners belong to different vertices")

	known := va if va != ct.INVALID_VERTEX else vb
	ct.set_ring(t, a, known)
}

finish_component :: proc(
	ds: ^Decoder_State,
	start: ct.Corner,
	first_vertex: ct.Vertex,
	comp: Component_Info,
) {
	for h in ds.pending_holes {
		ct.set_border(ds.t, h.tip, h.first, h.len)
	}
	clear(&ds.pending_holes)

	if comp.outer_boundary > 0 {
		ct.set_border(ds.t, gate_start(start), first_vertex, comp.outer_boundary)
	}
}

/********************************** ZIP ***************************************/

/*
Zip only if a waiting pair from right exists. (avoids already glued edges)
*/
zip_if_free_right :: proc(ds: ^Decoder_State, edge: ct.Corner) {
	if ds.t.op[edge] == FREE_RIGHT {zip(ds, edge)}
}

/*
Link the FREE-R edge (c)with FREE-L waiting pair, then continue if possible.
*/
zip :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for t.op[c] == FREE_RIGHT {
		b := zip_pair(t^, c)
		if t.op[b] != FREE_LEFT {return}

		t.op[c], t.op[b] = b, c
		relabel_fan(t, c, b)

		c = zip_next(t^, c, b)
	}
}

/*
Find first corner on vertex_of(c) which isn't linked.
*/
zip_pair :: proc(t: ct.Corner_Table, c: ct.Corner) -> ct.Corner {
	b := next(c)

	for steps := 0; is_linked(t.op[b]); steps += 1 {
		assert(steps < len(t.op), "zip: endless walk (corrupted input?)")
		b = next(t.op[b])
	}

	return b
}

/*
Every corner in fan between must has vertex_of(b).
prev(b) must be the vertex v
*/
relabel_fan :: proc(t: ^ct.Corner_Table, c, b: ct.Corner) {
	v := t.c2v[prev(b)]

	a := prev(c)
	t.c2v[prev(a)] = v

	for steps := 0; is_linked(t.op[a]) && a != b; steps += 1 {
		assert(steps < len(t.op), "zip: endless walk (corrupted input?)")
		a = prev(t.op[a])
		t.c2v[prev(a)] = v
	}
}

/*
After c and b were linked, where to continue zipping?
the free end on the other side of c
*/
zip_next :: proc(t: ct.Corner_Table, c, b: ct.Corner) -> ct.Corner {
	c := prev(c)

	for steps := 0; is_linked(t.op[c]) && c != b; steps += 1 {
		assert(steps < len(t.op), "zip: endless walk (corrupted input?)")
		c = prev(t.op[c])
	}

	return c
}

/******************************** CORNER TABLE ********************************/

/*
not linked edge = border. fill t.v2c and assert nothing unresolved
*/
finalize_corner_table :: proc(ds: ^Decoder_State, loc := #caller_location) {
	t := ds.t

	for &o in t.op {
		if o < 0 {o = ct.INVALID_CORNER}
	}

	resize(&t.v2c, len(t.pos), loc)
	slice.fill(t.v2c[:], ct.INVALID_CORNER)

	for c in 0 ..< len(t.c2v) {
		v := t.c2v[c]
		assert(v != ct.INVALID_VERTEX, "unresolved corner")
		t.v2c[v] = ct.Corner(c)
	}

	for c in t.v2c {
		assert(c != ct.INVALID_CORNER, "unresolved vertex")
	}
}

@(disabled = ODIN_DISABLE_ASSERT)
assert_corner_table_consistent :: proc(t: ct.Corner_Table) {
	for i in 0 ..< len(t.op) {
		c := ct.Corner(i)
		o := t.op[c]
		if o == ct.INVALID_CORNER {continue}

		assert(t.op[o] == c, "op is not symmetric")
		assert(t.c2v[next(c)] == t.c2v[prev(o)], "shared edge: start vertices differ")
		assert(t.c2v[prev(c)] == t.c2v[next(o)], "shared edge: end vertices differ")
	}
}

/**************************** PASS 2: GEOMETRY ********************************/

/*
Decode geometry of one component.
*/
decode_component_geometry :: proc(ds: ^Decoder_State, start: ct.Corner, comp: Component_Info) {
	decode_gate_vertices(ds, start, comp.outer_boundary > 0)
	decode_geometry_triangles(ds, start)
}

/*
Decode first vertices in component, different for boundary&closed component.
*/
decode_gate_vertices :: proc(ds: ^Decoder_State, tip: ct.Corner, has_boundary: bool) {
	t := ds.t
	gs_c := gate_start(tip)
	gs := ct.c2v(t^, gs_c)

	t.pos[gs] = read_vertex(ds)
	ds.vertex_done[gs] = true

	if has_boundary {
		decode_hole_vertices(ds, gs_c)
	} else {
		ge := ct.c2v(t^, gate_end(tip))
		t.pos[ge] = ds.vtx_codec.decode_loop(t.pos[gs], read_vertex(ds))
		ds.vertex_done[ge] = true
	}
}

decode_geometry_triangles :: proc(ds: ^Decoder_State, start: ct.Corner) {
	t := ds.t^
	assert(len(ds.gate_stack) == 0, "gate stack must be empty between components")

	gate := start
	for gate != ct.INVALID_CORNER {
		ds.tri_done[ct.c2t(gate)] = true

		// symbol must be decided before tip is decoded (known vs not)
		symbol := geometry_symbol(ds, gate)
		decode_tip_vertex(ds, gate)

		switch symbol {
		case .C, .L:
			gate = ct.right_of(t, gate)
		case .R:
			gate = ct.left_of(t, gate)
		case .S:
			push_gate(ds, ct.left_of(t, gate))
			gate = ct.right_of(t, gate)
		case .E:
			gate = pop_undecoded_gate(ds)
		}
	}
}

/*
Is exactly the same decision as in encoder decide_clers.
*/
geometry_symbol :: proc(ds: ^Decoder_State, gate: ct.Corner) -> Operation {
	t := ds.t^

	tip_is_new := !ds.vertex_done[ct.c2v(t, gate)] && !ct.border_c(t, gate)
	right_done := neighbour_done(ds^, ct.right_of(t, gate))
	left_done := neighbour_done(ds^, ct.left_of(t, gate))

	return clers_symbol(tip_is_new, right_done, left_done)
}

// border = also done
neighbour_done :: proc(ds: Decoder_State, c: ct.Corner) -> bool {
	return c == ct.INVALID_CORNER || ds.tri_done[ct.c2t(c)]
}

/*
Decode the tip vertex position if tip is new.

Encoder brother = smart_vertex_emit
*/
decode_tip_vertex :: proc(ds: ^Decoder_State, gate: ct.Corner) {
	t := ds.t
	v := ct.c2v(t^, gate)
	if ds.vertex_done[v] {return}

	if tip_prediction_available(ds^, gate) {
		ctx := vertex_codec_context(t^, gate)
		t.pos[v] = ds.vtx_codec.decode_tip(ctx, read_vertex(ds))
	} else {
		ge := ct.c2v(t^, gate_end(gate))
		t.pos[v] = ds.vtx_codec.decode_loop(t.pos[ge], read_vertex(ds))
	}
	ds.vertex_done[v] = true

	if ct.border_c(t^, gate) {
		decode_hole_vertices(ds, gate)
	}
}

// the op vtx to gate exists & is decoded
tip_prediction_available :: proc(ds: Decoder_State, gate: ct.Corner) -> bool {
	o := ct.op(ds.t^, gate)
	return o != ct.INVALID_CORNER && ds.vertex_done[ct.c2v(ds.t^, o)]
}

decode_hole_vertices :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	initial := ct.c2v(t^, c)
	curr := c

	for {
		n, found := ct.next_on_border(t^, curr)
		assert(found, "border walk left the border...")

		v := ct.c2v(t^, n)
		if v == initial {return} 	// the loop has endeth

		prev_pos := t.pos[ct.c2v(t^, curr)]
		t.pos[v] = ds.vtx_codec.decode_loop(prev_pos, read_vertex(ds))
		ds.vertex_done[v] = true

		curr = n
	}
}

/****************************** Helpers ***************************************/

is_linked :: #force_inline proc(c: ct.Corner) -> bool {return c >= 0}

read_symbol :: proc(ds: ^Decoder_State) -> Operation {
	assert(ds.sym_pos < len(ds.symbols), "ran out of symbols")
	s := ds.symbols[ds.sym_pos]
	ds.sym_pos += 1
	return s
}

read_vertex :: proc(ds: ^Decoder_State) -> Vector3 {
	assert(ds.vtx_pos < len(ds.vertices), "ran out of vertices")
	v := ds.vertices[ds.vtx_pos]
	ds.vtx_pos += 1
	return v
}

reserve_vertex_id :: proc(ds: ^Decoder_State) -> ct.Vertex {
	ds.last_vertex += 1
	return ds.last_vertex
}

// return the first id
reserve_vertex_ids :: proc(ds: ^Decoder_State, n: int) -> ct.Vertex {
	first := ds.last_vertex + 1
	ds.last_vertex += ct.Vertex(n)
	return first
}

// tip of new (next) triangle
peek_next_tip :: proc(ds: Decoder_State) -> ct.Corner {
	return ct.Corner(3 * (ds.last_tri + 1))
}

// count a new triangle, return tip
new_triangle :: proc(ds: ^Decoder_State) -> ct.Corner {
	tip := peek_next_tip(ds^)
	ds.last_tri += 1
	return tip
}

/*
Pushes gate to ds.gate_stack.
*/
push_gate :: #force_inline proc(ds: ^Decoder_State, gate: ct.Corner) {
	append(&ds.gate_stack, Gate(gate))
}

/*
Pop gate stack until not linked gate is found.
*/
pop_unlinked_gate :: #force_inline proc(ds: ^Decoder_State) -> ct.Corner {
	for len(ds.gate_stack) > 0 {
		candidate := ct.Corner(pop(&ds.gate_stack))

		if !is_linked(ds.t.op[candidate]) {return candidate}
	}
	return ct.INVALID_CORNER
}

pop_undecoded_gate :: proc(ds: ^Decoder_State) -> ct.Corner {
	for len(ds.gate_stack) > 0 {
		candidate := ct.Corner(pop(&ds.gate_stack))

		if !ds.tri_done[ct.c2t(candidate)] {return candidate}
	}
	return ct.INVALID_CORNER
}
