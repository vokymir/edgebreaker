package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:slice"

// cannot be the papers -1 and -2 because -1 is indicating invalid vertex in CT
@(private = "file")
FREE_LEFT_CORNER :: ct.Corner(-10)
@(private = "file")
FREE_RIGHT_CORNER :: ct.Corner(-20)

@(private = "file")
Vertex_Mark :: enum {
	NOT_VISITED,
	VISITED,
}

@(private = "file")
Triangle_Mark :: enum {
	NOT_VISITED,
	VISITED,
}

@(private = "file")
Decoding_State :: struct {
	// all vertices in the first-seen order
	V:         []ct.Vertex,
	// oposites
	O:         []ct.Corner,
	// current triangle
	T:         ct.Triangle,
	// current gate
	N:         ct.Vertex,
	// geometry
	G:         Vec3,

	// purely temporal

	// was vertex visited
	M:         []Vertex_Mark,
	// was triangle visited
	U:         []Triangle_Mark,

	// diversion from the pure paper

	// position in the clers string
	clers_pos: int,
	// position in the vertex stream
	delta_pos: int,

	// just practical
	allocator: runtime.Allocator,
}

@(private = "file")
init_ds :: proc(
	ds: ^Decoding_State,
	em: Encoded_Mesh,
	allocator := context.allocator,
	loc := #caller_location,
) {
	n_vertices := len(em.vertices)
	n_triangles := len(em.symbols)

	ds.allocator = allocator

	ds.V = make([]ct.Vertex, n_vertices, allocator, loc)
	slice.fill(ds.V[:], ct.INVALID_VERTEX)
	ds.O = make([]ct.Corner, n_triangles * 3, allocator, loc)
	slice.fill(ds.O[:], ct.INVALID_CORNER)

	ds.T = ct.INVALID_TRIANGLE
	ds.N = ct.INVALID_VERTEX

	ds.M = make([]Vertex_Mark, n_vertices, allocator, loc)
	slice.fill(ds.M[:], .NOT_VISITED)
	ds.U = make([]Triangle_Mark, n_triangles, allocator, loc)
	slice.fill(ds.U[:], .NOT_VISITED)

	ds.clers_pos = 0
	ds.delta_pos = 0
}

@(private = "file")
destroy_ds :: proc(ds: ^Decoding_State, loc := #caller_location) {
	delete(ds.V, ds.allocator, loc)
	delete(ds.O, ds.allocator, loc)
	delete(ds.M, ds.allocator, loc)
	delete(ds.U, ds.allocator, loc)
}

@(private)
decode_wrap_and_zip_ct :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	ds: Decoding_State
	init_ds(&ds, em, allocator, loc)
	defer destroy_ds(&ds)

	ds.V[0] = 0; ds.V[1] = 1; ds.V[2] = 2
	ds.O[0] = FREE_LEFT_CORNER; ds.O[2] = FREE_LEFT_CORNER

	ds.T = 0
	ds.N = 2

	return true
}

@(private = "file")
decode_connectivity :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c

	for {
		ds.T += 1
		ds.O[c] = ct.Corner(3 * ds.T); ds.O[3 * ds.T] = c
		c = ct.next(ds.O[c])

		switch read_clers(ds, em) {
		case .C:
			ds.O[ct.next(c)] = ct.INVALID_CORNER
			ds.N += 1
			ds.V[3 * ds.T] = ds.N
		case .L:
			ds.O[ct.next(c)] = FREE_RIGHT_CORNER
			zip(ds, em, ct.next(c))
		case .R:
			ds.O[c] = FREE_RIGHT_CORNER
			c = ct.next(c)
		case .S:
			decode_connectivity(ds, em, c)
			c = ct.next(c)
		case .E:
			ds.O[c] = FREE_RIGHT_CORNER
			ds.O[ct.next(c)] = FREE_RIGHT_CORNER
			zip(ds, em, ct.next(c))
			return
		}
	}
}

@(private = "file")
decode_vertices :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c

	for {
		ds.U[ct.c2t(c)] = .VISITED

		if ds.M[ct.c2t(c)] != .VISITED {
			ds.N += 1
			ds.G[ds.N] = 0 // TODO: use predictor here with read_delta()

			ds.M[ds.V[c]] = .VISITED
			c = ds.O[ct.next(c)] // TODO: c.r & c.l clarity helper
		} else {
			if ds.U[ct.c2t(ds.O[ct.prev(c)])] == .VISITED {
				if ds.U[ct.c2t(ds.O[ct.next(c)])] == .VISITED {
					return
				} else {
					c = ds.O[ct.prev(c)]
				}
			} else {
				if ds.U[ct.c2t(ds.O[ct.next(c)])] == .VISITED {
					c = ds.O[ct.next(c)]
				} else {
					decode_vertices(ds, em, ds.O[ct.next(c)])
					c = ds.O[ct.prev(c)]
				}
			}
		}
	}
}

@(private = "file")
zip :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c
	b := ct.next(c)

	for ds.O[b] >= 0 {
		b = ct.next(ds.O[b])
	}

	if ds.O[b] != FREE_LEFT_CORNER {return}

	ds.O[c] = b; ds.O[b] = c
	a := ct.prev(c); ds.V[ct.prev(a)] = ds.V[ct.prev(b)]

	for ds.O[a] >= 0 && b != a {
		a = ds.O[ct.prev(a)]
		ds.V[ct.prev(a)] = ds.V[ct.prev(b)]
	}

	c = ct.prev(c)
	for ds.O[c] >= 0 && c != b {
		c = ds.O[ct.prev(c)]
	}

	if ds.O[c] == FREE_RIGHT_CORNER {zip(ds, em, c)}
}

// TODO: boundary checks
@(private = "file")
read_clers :: #force_inline proc(ds: ^Decoding_State, em: Encoded_Mesh) -> Operation {
	op := em.symbols[ds.clers_pos]
	ds.clers_pos += 1

	return op
}
