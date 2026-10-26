#+private file
package edgebreaker

import ct "../corner_table"
import "base:runtime"
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
	predictor:   Predictor,
	allocator:   runtime.Allocator,

	// connectivity pass
	sym_pos:     int,
	last_tri:    ct.Triangle,
	last_vertex: ct.Vertex,

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
		predictor   = predictor_of(em.predictor),
		allocator   = allocator,
		last_tri    = ct.INVALID_TRIANGLE,
		last_vertex = ct.INVALID_VERTEX,
		vertex_done = make([]bool, n_vertices, allocator, loc),
		tri_done    = make([]bool, n_triangles, allocator, loc),
	}
}

destroy_ds :: proc(ds: ^Decoder_State, loc := #caller_location) {
	delete(ds.vertex_done, ds.allocator, loc)
	delete(ds.tri_done, ds.allocator, loc)
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
	if comp.outer_boundary != 0 {
		panic("TODO: components with boundary")
	}
	assert(read_symbol(ds) == .C, "first triangle in closed component must be C")

	ds.last_tri += 1
	base := ct.Corner(3 * ds.last_tri)

	// TODO: initial triangle ordering
	ds.t.c2v[base + 1] = new_vertex_id(ds) // gs
	ds.t.c2v[base + 2] = new_vertex_id(ds) // ge
	ds.t.c2v[base + 0] = new_vertex_id(ds) // tip

	ds.t.op[base + 0] = FREE_LEFT
	ds.t.op[base + 2] = FREE_LEFT
	return base + 1
}

decode_connectivity :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for {
		c = attach_triangle(ds, c)

		right_edge, left_edge := c, next(c)
		tip := prev(c)

		switch read_symbol(ds) {
		case .C:
			t.op[left_edge] = FREE_LEFT
			t.c2v[tip] = new_vertex_id(ds)
		case .L:
			t.op[left_edge] = FREE_RIGHT
			zip(ds, left_edge)
		case .R:
			t.op[right_edge] = FREE_RIGHT
			c = left_edge
		case .S:
			decode_connectivity(ds, right_edge)
			c = left_edge
		case .E:
			t.op[right_edge] = FREE_RIGHT
			t.op[left_edge] = FREE_RIGHT
			zip(ds, left_edge)
			return
		}
	}
}

attach_triangle :: proc(ds: ^Decoder_State, c: ct.Corner) -> ct.Corner {
	t := ds.t
	ds.last_tri += 1
	tip := ct.Corner(3 * ds.last_tri)

	t.op[c], t.op[tip] = tip, c

	t.c2v[tip + 1] = ct.c2v(t^, prev(c))
	t.c2v[tip + 2] = ct.c2v(t^, next(c))

	return next(tip)
}

zip :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for {
		b := next(c)
		for is_linked(t.op[b]) {b = next(t.op[b])}
		if t.op[b] != FREE_LEFT {return}

		t.op[c], t.op[b] = b, c

		// all corners around this vertex must reference this vertex now
		a := prev(c)
		t.c2v[prev(a)] = ct.c2v(t^, prev(b))
		for is_linked(t.op[a]) && a != b {
			a = prev(t.op[a])
			t.c2v[prev(a)] = ct.c2v(t^, prev(b))
		}

		// return if done, continue with c if we should
		c = prev(c)
		for is_linked(t.op[c]) && c != b {c = prev(t.op[c])}
		if t.op[c] != FREE_RIGHT {return}
	}
}

decode_geometry_from :: proc(ds: ^Decoder_State, start: ct.Corner) {
	t := ds.t
	base := start - 1

	// TODO: ordering of initial triangle vertices
	for corner in ([3]ct.Corner{base + 1, base + 2, base}) {
		v := ct.c2v(t^, corner)
		t.pos[v] = read_vertex(ds)
		ds.vertex_done[v] = true
	}
	ds.tri_done[ct.c2t(base)] = true
	decode_geometry(ds, t.op[start])
}

decode_geometry :: proc(ds: ^Decoder_State, c: ct.Corner) {
	t := ds.t
	c := c

	for {
		ds.tri_done[ct.c2t(c)] = true

		v := ct.c2v(t^, c)
		if !ds.vertex_done[v] { 	// C
			t.pos[v] = ds.predictor.predict(predictor_input(t^, c)) + read_vertex(ds)
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
