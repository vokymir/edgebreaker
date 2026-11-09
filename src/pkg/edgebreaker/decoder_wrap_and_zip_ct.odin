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
	t:           ^ct.Corner_Table,
	symbols:     []Operation,
	vertices:    []Vector3,
	predictor:   Vertex_Codec,
	allocator:   runtime.Allocator,

	//
	gate_stack:  [dynamic]Gate,

	// connectivity pass
	sym_pos:     int,
	last_tri:    ct.Triangle,
	last_vertex: ct.Vertex,
	holes:       map[int]int, // map tip corner -> hole len
	glues:       map[int]int, // map corner -> corner (arrival to S-left)

	// geometry pass
	vtx_pos:     int,
	vertex_done: []bool,
	tri_done:    []bool,
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

	resize(&t.pos, n_vertices, loc)
	resize(&t.c2v, 3 * n_triangles, loc)
	resize(&t.op, 3 * n_triangles, loc)
	slice.fill(t.c2v[:], ct.INVALID_VERTEX)
	slice.fill(t.op[:], ct.INVALID_CORNER)

	ds^ = Decoder_State {
		t           = t,
		symbols     = em.symbols[:],
		vertices    = em.vertices[:],
		predictor   = vertex_codec_of(em.vertex_codec),
		allocator   = allocator,
		//
		gate_stack  = make([dynamic]Gate, allocator, loc),
		//
		sym_pos     = 0,
		last_tri    = ct.INVALID_TRIANGLE,
		last_vertex = ct.INVALID_VERTEX,
		//
		vtx_pos     = 0,
		vertex_done = make([]bool, n_vertices, allocator, loc),
		tri_done    = make([]bool, n_triangles, allocator, loc),
	}

	ds.holes = make(map[int]int, allocator, loc)
	ds.glues = make(map[int]int, allocator, loc)
	for top in em.topology {
		arrival_corner := top.arrival_step * 3 + int(top.arrival_side)
		s_corner := top.s_step + 2 // always left side
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
}

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
		start := begin_component(&ds, comp)
		append(&starts, start)
		decode_connectivity(&ds, start)
	}
	assert(ds.sym_pos == len(ds.symbols), "unused symbols")

	resize(&t.v2c, len(t.pos), loc)
	for c in 0 ..< len(t.c2v) {t.v2c[t.c2v[c]] = ct.Corner(c)}

	// pass 2: geometry
	for start in starts {decode_geometry_from(&ds, start)}
	assert(ds.vtx_pos == len(ds.vertices), "unused vertices")
}

begin_component :: proc(ds: ^Decoder_State, comp: Component_Info) -> ct.Corner {
	log.debug("begin component", comp)
	this_tri := ds.last_tri + 1
	base := ct.Corner(3 * this_tri)

	if comp.outer_boundary != 0 { 	// BOUNDARY COMPONENT
		// reserve boundary vertices
		log.debug("boundary component")

		ds.t.c2v[base + 2] = new_vertex_id(ds)
		// minus 2: the ge and gs
		for i in 0 ..< (comp.outer_boundary - 2) {new_vertex_id(ds)}
		ds.t.c2v[base + 1] = new_vertex_id(ds)

	} else { 	// CLOSED COMPONENT
		log.debug("closed component")

		ds.t.c2v[base + 1] = new_vertex_id(ds) // gs
		ds.t.c2v[base + 2] = new_vertex_id(ds) // ge

		ds.t.op[base + 0] = FREE_LEFT
		ds.t.op[base + 2] = FREE_LEFT
	}

	return -1 * base
}

decode_connectivity :: proc(ds: ^Decoder_State, c: ct.Corner) {
	log.debug("decode connectivity", c)
	t := ds.t
	c := c

	for {
		c = attach_triangle(ds, c)

		tip := c
		right_edge, left_edge := next(c), prev(c)

		glue(ds, tip)

		switch read_symbol(ds) {
		case .C:
			t.op[left_edge] = FREE_LEFT
			t.c2v[tip] = new_vertex_id(ds)
			c = right_edge
		case .L:
			t.op[left_edge] = FREE_RIGHT
			zip(ds, left_edge)
			c = right_edge
		case .R:
			t.op[right_edge] = FREE_RIGHT
			c = left_edge
		case .S:
			push_gate(ds, left_edge)
			c = right_edge
		case .E:
			t.op[right_edge] = FREE_RIGHT
			t.op[left_edge] = FREE_RIGHT
			zip(ds, left_edge)
			c = pop_unvisited(ds)
			if c == ct.INVALID_CORNER {return}
		}
	}
}

attach_triangle :: proc(ds: ^Decoder_State, c: ct.Corner) -> ct.Corner {
	log.debug("attach triangle")
	c := c
	t := ds.t
	ds.last_tri += 1
	tip := ct.Corner(3 * ds.last_tri)

	if c > 0 { 	// standard situation
		log.debug("standard")
		t.op[c], t.op[tip] = tip, c

		t.c2v[tip + 1] = ct.c2v(t^, prev(c))
		t.c2v[tip + 2] = ct.c2v(t^, next(c))

		// in initial triangle, nothing is to do
	} else { 	// initial triangle
		log.debug("initial")
		c *= -1
	}

	return tip
}

glue :: proc(ds: ^Decoder_State, tip: ct.Corner) {
	tip: int = int(tip)
	t := ds.t

	// HOLES
	if len, ok := ds.holes[tip]; ok {
		for i in 0 ..< len {new_vertex_id(ds)}
		delete_key(&ds.holes, tip)
	}

	// GLUING CORNERS
	candidates := [3]int{tip, tip + 1, tip + 2}

	gluing_edge := ct.INVALID_CORNER

	for candidate in candidates {
		if candidate in ds.glues {gluing_edge = ct.Corner(candidate); break}
	}

	if gluing_edge == ct.INVALID_CORNER {return}

	s := ds.glues[int(gluing_edge)]
	s_corner := ct.Corner(s)

	t.op[gluing_edge] = ct.Corner(s_corner)
	t.op[s_corner] = ct.Corner(gluing_edge)

	t.c2v[gluing_edge + 1] = ct.c2v(t^, prev(s_corner))
	t.c2v[gluing_edge + 2] = ct.c2v(t^, next(s_corner))

	zip(ds, ct.Corner(gluing_edge))
}

zip :: proc(ds: ^Decoder_State, c: ct.Corner) {
	log.debug("zip")
	t := ds.t
	c := c

	for {
		b := next(c)
		for is_linked(t.op[b]) {b = next(t.op[b])}
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

// TODO: ALL GEOMETRY
decode_geometry_from :: proc(ds: ^Decoder_State, start: ct.Corner) {
	log.debug("DGF")
	t := ds.t
	base := start - 1

	// TODO: ordering of initial triangle vertices
	for corner in ([3]ct.Corner{base + 1, base + 2, base}) {
		log.debug("in")
		v := ct.c2v(t^, corner) // TODO: HERE IS -1 index
		log.debug("out")
		t.pos[v] = read_vertex(ds)
		ds.vertex_done[v] = true
	}
	ds.tri_done[ct.c2t(base)] = true
	decode_geometry(ds, t.op[start])
}

// TODO: ALL GEOMETRY
decode_geometry :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for {
		ds.tri_done[ct.c2t(c)] = true

		v := ct.c2v(t^, c)
		if !ds.vertex_done[v] { 	// C
			// t.pos[v] = ds.predictor.predict(vertex_codec_context(t^, c)) + read_vertex(ds)
			ds.vertex_done[v] = true
			c = ct.right_of(t^, c)
			continue
		}

		right_done := ds.tri_done[ct.c2t(ct.right_of(t^, c))]
		left_done := ds.tri_done[ct.c2t(ct.left_of(t^, c))]
		switch {
		case right_done && left_done:
			return
		case right_done:
			c = ct.left_of(t^, c)
		case left_done:
			c = ct.right_of(t^, c)
		case:
			// S :)
			decode_geometry(ds, ct.right_of(t^, c))
			c = ct.left_of(t^, c)
		}
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
