package edgebreaker
/* Public API of compression. */

Vector3 :: [3]f32

/***************************** Structs ****************************************/
/* NOTE: another structs are in related compression files, notably in
encoder_ct.odin

Those structs are implementation-dependant, while these here are not.
*/


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
