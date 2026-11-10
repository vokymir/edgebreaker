#+private file
package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
import "core:slice"

next :: ct.next
prev :: ct.prev

// must not collide with ct.INVALID_CORNER
FREE_LEFT :: ct.Corner(-10)
FREE_RIGHT :: ct.Corner(-20)

Decoder_State :: struct {
	t:             ^ct.Corner_Table,
	symbols:       []Operation,
	vertices:      []Vector3,
	allocator:     runtime.Allocator,

	//
	gate_stack:    [dynamic]Gate,

	// connectivity pass
	sym_pos:       int,
	last_tri:      ct.Triangle,
	last_vertex:   ct.Vertex,
	holes:         map[int]int, // map tip corner -> hole len
	glues:         map[int]int, // map corner -> corner (arrival to S-left)
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

	assert(len(t.pos) == 0, "not empty corner table")
	assert(len(t.c2v) == 0, "not empty corner table")
	assert(len(t.op) == 0, "not empty corner table")
	assert(len(t.v2c) == 0, "not empty corner table")

	resize(&t.pos, n_vertices, loc)
	resize(&t.c2v, 3 * n_triangles, loc)
	resize(&t.op, 3 * n_triangles, loc)
	slice.fill(t.c2v[:], ct.INVALID_VERTEX)
	slice.fill(t.op[:], ct.INVALID_CORNER)

	ds^ = Decoder_State {
		t             = t,
		symbols       = em.symbols[:],
		vertices      = em.vertices[:],
		allocator     = allocator,
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

	ds.holes = make(map[int]int, allocator, loc)
	ds.glues = make(map[int]int, allocator, loc)
	for top in em.topology {
		arrival_corner := 3 * top.arrival_step + int(top.arrival_side)
		s_corner := 3 * top.s_step + 2 // always left side
		ds.glues[arrival_corner] = s_corner

		if top.hole_len < 1 {continue}
		tip_corner := top.s_step * 3
		hole := top.hole_len
		ds.holes[tip_corner] = hole
	}
}

destroy_ds :: proc(ds: ^Decoder_State, loc := #caller_location) {
	delete(ds.vertex_done, ds.allocator, loc)
	delete(ds.tri_done, ds.allocator, loc)
	delete(ds.gate_stack, loc)
	delete(ds.holes, loc)
	delete(ds.glues, loc)
	delete(ds.pending_holes, loc)
}

Pending_Hole :: struct {
	tip:   ct.Corner,
	first: ct.Vertex,
	len:   int,
}

/******************************************************************************/

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
	starts := make([dynamic]ct.Corner, allocator, loc)
	defer delete(starts)

	// pass 1: connectivity
	for comp in em.components {
		log.debug("component", comp)
		start, first_vertex_id := begin_component(&ds, comp)
		append(&starts, start)
		decode_connectivity(&ds, start)
		for h in ds.pending_holes {ct.set_border(ds.t, h.tip, h.first, h.len)}
		clear(&ds.pending_holes)

		if comp.outer_boundary > 0 { 	// set border corners to point to its vertices
			ct.set_border(ds.t, start + 1, first_vertex_id, comp.outer_boundary)
		}
	}
	assert(ds.sym_pos == len(ds.symbols), "unused symbols")
	assert(int(ds.last_vertex + 1) == len(em.vertices), "missing vertex")
	for &o in t.op {if o < 0 {o = ct.INVALID_CORNER}}

	log.debug(t)
	resize(&t.v2c, len(t.pos), loc)
	slice.fill(t.v2c[:], ct.INVALID_CORNER)
	for c in 0 ..< len(t.c2v) {
		assert(t.c2v[c] != ct.INVALID_VERTEX, "unresolved corner")
		t.v2c[t.c2v[c]] = ct.Corner(c)
	}
	for v in 0 ..< len(t.v2c) {assert(t.v2c[v] != ct.INVALID_CORNER, "unresolved vertex")}

	log.debug(ds)
	// pass 2: geometry
	for start in starts {decode_geometry_from(&ds, start)}
	assert(ds.vtx_pos == len(ds.vertices), "unused vertices")
}

begin_component :: proc(ds: ^Decoder_State, comp: Component_Info) -> (ct.Corner, ct.Vertex) {
	log.debug("begin component", comp)
	this_tri := ds.last_tri + 1
	base := ct.Corner(3 * this_tri)

	first_vertex_id := new_vertex_id(ds)

	if comp.outer_boundary != 0 { 	// BOUNDARY COMPONENT
		// reserve boundary vertices
		log.debug("boundary component")

		ds.t.c2v[base + 1] = first_vertex_id // gs
		// minus 2: the gs and ge
		for i in 0 ..< (comp.outer_boundary - 2) {new_vertex_id(ds)}
		ds.t.c2v[base + 2] = new_vertex_id(ds) // ge

	} else { 	// CLOSED COMPONENT
		log.debug("closed component")

		ds.t.c2v[base + 1] = first_vertex_id // gs
		ds.t.c2v[base + 2] = new_vertex_id(ds) // ge

		ds.t.op[base + 0] = FREE_LEFT
		ds.t.op[base + 2] = FREE_LEFT
	}

	return base, first_vertex_id
}

/*
*/
decode_connectivity :: proc(ds: ^Decoder_State, c: ct.Corner) {
	log.debug("decode connectivity", c)
	t := ds.t
	c := c
	initial := true

	// TODO: extract from a proc
	// mark an edge free only if glue hasn't already linked it
	set_free :: proc(t: ^ct.Corner_Table, e, mark: ct.Corner) {
		if !is_linked(t.op[e]) {t.op[e] = mark}
	}

	for {
		c = attach_triangle(ds, c, initial)
		initial = false

		tip := c
		right_edge, left_edge := next(c), prev(c)

		glue(ds, tip)

		switch read_symbol(ds) {
		case .C:
			t.op[left_edge] = FREE_LEFT
			t.c2v[tip] = new_vertex_id(ds)
			c = right_edge
		case .L:
			set_free(t, left_edge, FREE_RIGHT)
			if t.op[left_edge] == FREE_RIGHT {zip(ds, left_edge)}
			c = right_edge
		case .R:
			set_free(t, right_edge, FREE_RIGHT)
			c = left_edge
		case .S:
			push_gate(ds, left_edge)
			c = right_edge
		case .E:
			set_free(t, right_edge, FREE_RIGHT)
			set_free(t, left_edge, FREE_RIGHT)
			if t.op[left_edge] == FREE_RIGHT {zip(ds, left_edge)}
			c = pop_unvisited(ds)
		}

		if c == ct.INVALID_CORNER {break}
	}
}

attach_triangle :: proc(ds: ^Decoder_State, c: ct.Corner, initial: bool = false) -> ct.Corner {
	log.debug("attach triangle from corner", c)
	c := c
	t := ds.t
	ds.last_tri += 1
	tip := ct.Corner(3 * ds.last_tri)

	if !initial { 	// standard situation
		log.debug("standard")
		t.op[c], t.op[tip] = tip, c

		t.c2v[tip + 1] = ct.c2v(t^, prev(c))
		t.c2v[tip + 2] = ct.c2v(t^, next(c))

		// in initial triangle, nothing is to do
	} else { 	// initial triangle
		log.debug("initial")
	}

	return tip
}

glue :: proc(ds: ^Decoder_State, tip: ct.Corner) {
	log.debug("try glue for", tip)
	tip: int = int(tip)
	t := ds.t

	// HOLES on S corner
	if n, ok := ds.holes[tip]; ok {
		log.debug("hole on S corner")
		first := new_vertex_id(ds)
		for i in 0 ..< (n - 1) {new_vertex_id(ds)} 	// -1 for the first
		t.c2v[tip] = first
		append(&ds.pending_holes, Pending_Hole{ct.Corner(tip), first, n})
	}

	// GLUING CORNERS - HOLES or HANDLES on arr corner
	log.debug("try gluing corner - hole or handle")

	for side in 1 ..= 2 {
		corner := ct.Corner(int(tip) + side)
		s, ok := ds.glues[int(corner)]
		if !ok {continue}
		log.debug("gluing on corner", corner)
		s_corner := ct.Corner(s)

		log.debug("prev")
		t.op[corner] = s_corner
		t.op[s_corner] = corner
		log.debug("post")

		join_vertex(t, next(corner), prev(s_corner))
		join_vertex(t, prev(corner), next(s_corner))
	}

	log.debug("end try-glue")
}

join_vertex :: proc(t: ^ct.Corner_Table, a, b: ct.Corner) {
	va, vb := t.c2v[a], t.c2v[b]
	if va == ct.INVALID_VERTEX && vb == ct.INVALID_VERTEX {return}

	assert(va == vb || va == ct.INVALID_VERTEX || vb == ct.INVALID_VERTEX)
	ct.set_ring(t, a, va if va != ct.INVALID_VERTEX else vb)
}

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
