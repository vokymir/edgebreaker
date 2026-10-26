package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:log"
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
	// current triangle
	T:         ct.Triangle,
	// current gate
	N:         ct.Vertex,
	// corner table to store V, O, G
	t:         ^ct.Corner_Table,

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
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	n_vertices := len(em.vertices)
	n_triangles := len(em.symbols)

	ds.allocator = allocator

	if t == nil {
		log.debug("Corner Table passed to Decoding State is nil.")
	}
	ds.t = t

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
	delete(ds.M, ds.allocator, loc)
	delete(ds.U, ds.allocator, loc)
}

/*
The corner table should be initialized beforehand.
*/
@(private)
decode_wrap_and_zip_ct :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	ds: Decoding_State
	init_ds(&ds, em, t, allocator, loc)
	defer destroy_ds(&ds)

	V_(&ds, 0, 0); V_(&ds, 1, 1); V_(&ds, 2, 2)
	O_(&ds, 0, FREE_LEFT_CORNER); O_(&ds, 2, FREE_LEFT_CORNER)

	ds.T = 0
	ds.N = 2

	decode_connectivity(&ds, em, 1)

	return true
}

@(private = "file")
decode_connectivity :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c

	for {
		ds.T += 1
		O_(ds, c, ct.Corner(3 * ds.T)); O_(ds, ct.Corner(3 * ds.T), c)
		c = N(O(ds^, c))

		switch read_clers(ds, em) {
		case .C:
			O_(ds, N(c), ct.INVALID_CORNER)
			ds.N += 1
			V_(ds, ct.Corner(3 * ds.T), ds.N)
		case .L:
			O_(ds, N(c), FREE_RIGHT_CORNER)
			zip(ds, em, N(c))
		case .R:
			O_(ds, c, FREE_RIGHT_CORNER)
			c = N(c)
		case .S:
			decode_connectivity(ds, em, c)
			c = N(c)
		case .E:
			O_(ds, c, FREE_RIGHT_CORNER)
			O_(ds, N(c), FREE_RIGHT_CORNER)
			zip(ds, em, N(c))
			return
		}
	}
}

@(private = "file")
decode_vertices :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c

	for {
		U_(ds, ct.Triangle(V(ds^, c)), .VISITED)

		if M(ds^, V(ds^, c)) != .VISITED {
			ds.N += 1
			G_(ds, ds.N, 0) // TODO: use predictor here with read_delta()

			M_(ds, V(ds^, c), .VISITED)
			c = R(ds^, c)
		} else {
			if c_r_t_u(ds^, c) == .VISITED {
				if c_l_t_u(ds^, c) == .VISITED {
					return
				} else {
					c = L(ds^, c)
				}
			} else {
				if c_l_t_u(ds^, c) == .VISITED {
					c = R(ds^, c)
				} else {
					decode_vertices(ds, em, R(ds^, c))
					c = L(ds^, c)
				}
			}
		}
	}
}

@(private = "file")
zip :: proc(ds: ^Decoding_State, em: Encoded_Mesh, c: ct.Corner) {
	c := c
	b := N(c)

	for O(ds^, b) >= 0 {
		b = N(O(ds^, b))
	}

	if O(ds^, b) != FREE_LEFT_CORNER {return}

	O_(ds, c, b); O_(ds, b, c)
	a := P(c); V_(ds, P(a), V(ds^, P(b)))

	for O(ds^, a) >= 0 && b != a {
		a = O(ds^, P(a))
		V_(ds, P(a), V(ds^, P(b)))
	}

	c = P(c)
	for O(ds^, c) >= 0 && c != b {
		c = O(ds^, P(c))
	}

	if O(ds^, c) == FREE_RIGHT_CORNER {zip(ds, em, c)}
}

/******************************* Clarity helpers ******************************/

// TODO: boundary checks
@(private = "file")
read_clers :: #force_inline proc(ds: ^Decoding_State, em: Encoded_Mesh) -> Operation {
	op := em.symbols[ds.clers_pos]
	ds.clers_pos += 1

	return op
}


/*
corner -> vertex 
*/
@(private = "file")
V :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Vertex {
	return ct.c2v(ds.t^, c)
}

/*
corner -> vertex 
*/
@(private = "file")
V_ :: #force_inline proc(ds: ^Decoding_State, c: ct.Corner, v: ct.Vertex) {
	for len(ds.t.tris) < int(c) {append(&ds.t.tris, ct.INVALID_VERTEX)}
	ds.t.tris[c] = v
}

/*
corner -> opposite corner
*/
@(private = "file")
O :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Corner {
	return ct.op(ds.t^, c)
}

/*
corner -> opposite corner
*/
@(private = "file")
O_ :: #force_inline proc(ds: ^Decoding_State, c: ct.Corner, op: ct.Corner) {
	for len(ds.t.op) < int(c) {append(&ds.t.op, ct.INVALID_CORNER)}
	ds.t.op[c] = op
}

/*
corner -> previous corner in triangle
*/
@(private = "file")
P :: #force_inline proc(c: ct.Corner) -> ct.Corner {
	return ct.prev(c)
}

/*
corner -> next corner in triangle
*/
@(private = "file")
N :: #force_inline proc(c: ct.Corner) -> ct.Corner {
	return ct.next(c)
}

/*
corner c -> corner c.r in right triangle:

      (c.v)
c.l --- c --- c.r
 \    /   \    /
  \  / c.t \  /
   c.n --- c.p
    \      /
     \    /
      c.o
*/
@(private = "file")
R :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Corner {
	return ct.op(ds.t^, ct.next(c))
}

/*
corner c -> corner c.l in left triangle:
(see R() for image)
*/
@(private = "file")
L :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Corner {
	return ct.op(ds.t^, ct.prev(c))
}

/*
vertex -> geometry (position in 3D)
*/
@(private = "file")
G :: #force_inline proc(ds: Decoding_State, v: ct.Vertex) -> Vec3 {
	return ds.t.pos[v]
}

/*
set geometry of vertex
*/
@(private = "file")
G_ :: #force_inline proc(ds: ^Decoding_State, v: ct.Vertex, pos: Vec3) {
	for len(ds.t.pos) < int(v) {append(&ds.t.pos, {0, 0, 0})}
	ds.t.pos[v] = pos
}

/*
vertex -> mark
*/
@(private = "file")
M :: #force_inline proc(ds: Decoding_State, v: ct.Vertex) -> Vertex_Mark {
	return ds.M[v]
}


/*
vertex -> mark
*/
@(private = "file")
M_ :: #force_inline proc(ds: ^Decoding_State, v: ct.Vertex, m: Vertex_Mark) {
	ds.M[v] = m
}

/*
triangle -> mark
*/
@(private = "file")
U :: #force_inline proc(ds: Decoding_State, t: ct.Triangle) -> Triangle_Mark {
	return ds.U[t]
}

/*
triangle -> mark
*/
@(private = "file")
U_ :: #force_inline proc(ds: ^Decoding_State, t: ct.Triangle, m: Triangle_Mark) {
	ds.U[t] = m
}

/*
mark of vertex of corner
*/
@(private = "file")
c_v_m :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> Vertex_Mark {
	return M(ds, V(ds, c))
}

/*
triangle of corner
*/
@(private = "file")
c_t :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Triangle {
	return ct.Triangle(V(ds, c))
}

/*
vertex of corner
*/
@(private = "file")
c_v :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> ct.Vertex {
	return V(ds, c)
}

/*
right triangle visited
*/
@(private = "file")
c_r_t_u :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> Triangle_Mark {
	return U(ds, c_t(ds, R(ds, c)))
}

/*
left triangle visited
*/
@(private = "file")
c_l_t_u :: #force_inline proc(ds: Decoding_State, c: ct.Corner) -> Triangle_Mark {
	return U(ds, c_t(ds, L(ds, c)))
}
