package edgebreaker
/* Public API of compression. */

import "base:runtime"
import "core:slice"

/* NOTE: another declarations might be in related compression files

Those declarations are dependant on some part of implementation or data
structure, while these here are univeral for edgebreaker.
*/

/***************************** Enums ******************************************/

/*
Marks vertices as the algorithm goes through the mesh.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
	HOLE,
}

/***************************** Structs ****************************************/

/*
Stores the state of edgebreaker algorithm during compression.
Is only used with corner table.
*/
@(private) // only used in the package
Encoder_State :: struct {
	// for destroy
	allocator:     runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:  []Mark,
	// in which step a triangle was discovered (0=never)
	tri_step:      []int,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:    [dynamic]Gate,
	// store S step -> number of hole vertices
	hole_len_of_s: map[int]int,

	// predicts position of next vertex
	vertex_codec:  Vertex_Codec,
	// ptr to resulting Vertex_Codec
	em:            ^Encoded_Mesh,
}

/***************************** Struct helpers *********************************/

/*
Initialize Encoder State for Edgebreaker compression with Corner Table.
*/
@(private) // only used in the package
init_es :: proc(
	es: ^Encoder_State,
	n_vertices, n_triangles: int,
	vertex_codec := Vertex_Codec_Raw,
	allocator := context.allocator,
	loc := #caller_location,
) {
	es.vertex_marks = make([]Mark, n_vertices, allocator, loc)
	slice.fill(es.vertex_marks[:], Mark.NOT_VISITED)

	es.tri_step = make([]int, n_triangles, allocator, loc)

	es.gate_stack = make([dynamic]Gate, allocator, loc)

	es.hole_len_of_s = make(map[int]int, allocator, loc)

	es.vertex_codec = vertex_codec
	es.allocator = allocator
}

/*
Destroy internals of Encoder State.
WARN: caller must deallocate vertex_codec (if necessary)
*/
@(private) // only used in the package
destroy_es :: proc(es: ^Encoder_State, loc := #caller_location) {
	delete(es.vertex_marks, es.allocator, loc)
	delete(es.tri_step, es.allocator, loc)
	delete(es.gate_stack, loc)
	delete(es.hole_len_of_s, loc)
}


/***************************** Compression ************************************/

compress :: proc {
	compress_ct,
}
