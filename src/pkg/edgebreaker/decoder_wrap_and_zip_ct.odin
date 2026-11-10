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
	start = peek_next_tip(ds)

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
	ds.t.c2v[tip] = new_vertex_id(ds)
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
	return pop_unlinked_gate(gs)
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

zip :: proc(ds: ^Decoder_State, c: ct.Corner) {
	log.debug("zip")
	t := ds.t
	c := c

	for {
		b := next(c)
		for is_linked(t.op[b]) {b = next(t.op[b])} 	// TODO: potential inf loop for
		// corrupted input (connected)
		if t.op[b] != FREE_LEFT {return}

		t.op[c], t.op[b] = b, c

		// all corners around this vertex must reference this vertex now
		a := prev(c)
		log.debug("1.1")
		t.c2v[prev(a)] = ct.c2v(t^, prev(b))
		log.debug("1.2")
		for is_linked(t.op[a]) && a != b {
			a = prev(t.op[a])
			log.debug("2.1")
			t.c2v[prev(a)] = ct.c2v(t^, prev(b))
			log.debug("2.2")
		}

		// return if done, continue with c if we should
		c = prev(c)
		for is_linked(t.op[c]) && c != b {c = prev(t.op[c])}
		if t.op[c] != FREE_RIGHT {return}
	}
}

decode_geometry_from :: proc(ds: ^Decoder_State, start: ct.Corner) {
	log.debug("DGF")
	t := ds.t

	gs_c := ct.next(start)
	gs_v := ct.c2v(t^, gs_c)
	ge_c := ct.prev(start)
	ge_v := ct.c2v(t^, ge_c)
	on_border := ct.border_c(t^, gs_c)
	log.debug("on border", on_border)

	if on_border {
		t.pos[gs_v] = read_vertex(ds)
		ds.vertex_done[gs_v] = true
		decode_geometry_hole(ds, gs_c)

	} else { 	// closed component
		t.pos[gs_v] = read_vertex(ds)
		t.pos[ge_v] = ds.vtx_codec.decode_loop(t.pos[gs_v], read_vertex(ds))
		ds.vertex_done[gs_v] = true
		ds.vertex_done[ge_v] = true
	}

	decode_geometry(ds, start)
}

decode_geometry :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for {
		ds.tri_done[ct.c2t(c)] = true
		log.debug(ds.vertex_done)

		v := ct.c2v(t^, c)
		log.debug("decoding from corner", c, "vertex", v)
		if !ds.vertex_done[v] { 	// C/S
			log.debug("C or S")
			standard_situation :=
				t.op[c] != ct.INVALID_CORNER && ds.vertex_done[ct.c2v(t^, t.op[c])] == true
			if standard_situation {
				log.debug("standard situation")
				t.pos[v] = ds.vtx_codec.decode_tip(vertex_codec_context(t^, c), read_vertex(ds))
			} else { 	// initial triangle
				log.debug("initial triangle")
				ge_c := ct.prev(c)
				ge_v := ct.c2v(t^, ge_c)
				t.pos[v] = ds.vtx_codec.decode_loop(t.pos[ge_v], read_vertex(ds))
			}

			ds.vertex_done[v] = true

			// try to decode hole, does nothing if not hole
			decode_geometry_hole(ds, c)

			c = ct.right_of(t^, c)
			continue
		}

		// TODO: extract out of this proc
		is_done :: proc(ds: ^Decoder_State, c: ct.Corner) -> bool {
			return c == ct.INVALID_CORNER || ds.tri_done[ct.c2t(c)]
		}

		// TODO: use stack again
		right_done := is_done(ds, ct.right_of(t^, c))
		left_done := is_done(ds, ct.left_of(t^, c))
		switch {
		case right_done && left_done:
			log.debug("E")
			return
		case right_done:
			log.debug("R")
			c = ct.left_of(t^, c)
		case left_done:
			log.debug("L")
			c = ct.right_of(t^, c)
		case:
			log.debug("S")
			decode_geometry(ds, ct.right_of(t^, c))
			c = ct.left_of(t^, c)
		}
	}
}

/*
Use loop decoding for all vertices starting from vertex of c.
The initial vertex is not decoded here, must be done before.
*/
decode_geometry_hole :: proc(ds: ^Decoder_State, c: ct.Corner) {
	curr := c
	t := ds.t
	initial := ct.c2v(t^, c)

	for {
		next, found := ct.next_on_border(t^, curr)
		if !found {
			log.debug("This is not a hole, just C.")
			return
		}

		v := ct.c2v(t^, next)
		if v == initial {return}

		prev_pos := t.pos[ct.c2v(t^, curr)]
		t.pos[v] = ds.vtx_codec.decode_loop(prev_pos, read_vertex(ds))
		ds.vertex_done[v] = true

		curr = next
	}
}


/****************************** Helpers ***************************************/

is_linked :: #force_inline proc(c: ct.Corner) -> bool {return c >= 0}

read_symbol :: proc(ds: ^Decoder_State) -> Operation {
	s := ds.symbols[ds.sym_pos]
	ds.sym_pos += 1
	return s
}

read_vertex :: proc(ds: ^Decoder_State) -> Vector3 {
	v := ds.vertices[ds.vtx_pos]
	ds.vtx_pos += 1
	return v
}

new_vertex_id :: proc(ds: ^Decoder_State) -> ct.Vertex {
	ds.last_vertex += 1
	return ds.last_vertex
}

/*
Pushes gate to ds.gate_stack.
*/
@(private = "file")
push_gate :: #force_inline proc(ds: ^Decoder_State, gate: ct.Corner) {
	append(&ds.gate_stack, Gate(gate))
}

/*
Pop gate stack until unvisited gate is found.
*/
@(private = "file")
pop_unvisited :: #force_inline proc(ds: ^Decoder_State) -> ct.Corner {
	for {
		if len(ds.gate_stack) == 0 {return ct.INVALID_CORNER}

		candidate := pop(&ds.gate_stack)

		already_done := ds.t.op[candidate] >= 0
		if !already_done {
			return ct.Corner(candidate)
		}
	}
}
