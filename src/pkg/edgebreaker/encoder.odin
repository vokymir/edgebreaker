package edgebreaker
/* Public API of compression. */

import "base:runtime"
import "core:slice"

/* NOTE: another declarations might be in related compression files

Those declarations are dependant on some part of implementation or data
structure, while these here are univeral for edgebreaker.
*/

Gate :: distinct int
Vector3 :: [3]f32

/***************************** Enums ******************************************/

/*
Marks vertices as the algorithm goes through the mesh.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
	HOLE,
}

/*
What is the operation done (= symbol emitted) on triangle?
*/
Operation :: enum {
	// finds new vertex
	C, // create
	// traverse the spanning tree
	L, // left
	R, // right
	// parantheses
	S, // split
	E, // end
}

Side :: enum u8 {
	RIGHT = 1,
	LEFT  = 2,
}


/***************************** Structs ****************************************/

/*
Stores the state of edgebreaker algorithm during compression.
Is only used with corner table.
*/
Encoder_State :: struct {
	// for destroy
	allocator:          runtime.Allocator,

	// as many as vertices, ordered as in ct.geometry
	vertex_marks:       []Mark,
	// in which step a triangle was discovered (0=never)
	tri_step:           []int,
	// store the opposite corner in the same triangle (ie the v corner)
	gate_stack:         [dynamic]Gate,
	// store S step -> number of hole vertices
	hole_len_of_s:      map[int]int,

	// flag necessary to handle first triangle
	first_in_component: bool,

	// predicts position of next vertex
	predictor:          Predictor,

	// ptr to resulting mesh
	em:                 ^Encoded_Mesh,
}

/*
Store the encoded mesh as a sequence of consecutive CLERS symbols, a list of all
vertices in the order of appeareance and a list of topology entries.

TODO: maybe it will need to store some additional metada, eg. predictor
*/
Encoded_Mesh :: struct {
	symbols:    [dynamic]Operation,
	vertices:   [dynamic]Vector3,
	topology:   [dynamic]Topology_Entry,
	components: [dynamic]Component_Info,
}


/*
Topology entry is necessary for every hole or handle.
It stores two gate corners & hole len.
*/
Topology_Entry :: struct {
	// at which step the symbol S was emitted
	s_step:       int,
	// at which step the next triangle would be the S triangle again
	arrival_step: int,
	// which side of arrival triangle it is
	arrival_side: Side,
	// if is not hole, hole_len == 0
	hole_len:     int,
}

/*
Store per-component metadata. Serializer might not use all of them.
*/
Component_Info :: struct {
	outer_boundary: int, // 0 for closed components
}

/***************************** Struct helpers *********************************/

/*
Initialize Encoder State for Edgebreaker compression with Corner Table.
*/
init_es :: proc(
	es: ^Encoder_State,
	n_vertices, n_triangles: int,
	predictor := Predictor_None,
	allocator := context.allocator,
	loc := #caller_location,
) {
	es.vertex_marks = make([]Mark, n_vertices, allocator, loc)
	slice.fill(es.vertex_marks[:], Mark.NOT_VISITED)

	es.tri_step = make([]int, n_triangles, allocator, loc)

	es.gate_stack = make([dynamic]Gate, allocator, loc)

	es.hole_len_of_s = make(map[int]int, allocator, loc)

	es.predictor = predictor
	es.allocator = allocator
}

/*
Destroy internals of Encoder State.
WARN: caller must deallocate predictor (if necessary)
*/
destroy_es :: proc(es: ^Encoder_State, loc := #caller_location) {
	delete(es.vertex_marks, es.allocator, loc)
	delete(es.tri_step, es.allocator, loc)
	delete(es.gate_stack, loc)
	delete(es.hole_len_of_s, loc)
}

/*
Initialize Encoded Mesh. If used with Encoder State (assumed usage) it can
self-attach to it (= set es.em).
*/
init_em :: proc(
	em: ^Encoded_Mesh,
	n_symbols: int = 0,
	n_vertices: int = 0,
	es: ^Encoder_State = nil,
	allocator := context.allocator,
	loc := #caller_location,
) {
	em.symbols = make([dynamic]Operation, 0, n_symbols, allocator, loc)
	em.vertices = make([dynamic]Vector3, 0, n_vertices, allocator, loc)
	em.topology = make([dynamic]Topology_Entry, 0, 0, allocator, loc)
	em.components = make([dynamic]Component_Info, 0, 0, allocator, loc)

	if es != nil {
		es.em = em
	}
}

/*
Destroy the internals of Encoded Mesh.
*/
destroy_em :: proc(em: ^Encoded_Mesh, loc := #caller_location) {
	delete(em.symbols, loc)
	delete(em.vertices, loc)
	delete(em.topology, loc)
	delete(em.components, loc)
}

/***************************** Compression ************************************/

compress :: proc {
	compress_ct,
}
