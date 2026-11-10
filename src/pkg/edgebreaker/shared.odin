package edgebreaker

import ct "../corner_table"

/*
Common logic for encoder and decoders.
*/

/***************************** TYPES ******************************************/

Gate :: distinct int

/***************************** ENUMS ******************************************/

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


/***************************** STRUCTS ****************************************/

/*
Store the encoded mesh as a sequence of consecutive CLERS symbols, a list of all
vertices in the order of appeareance and a list of topology entries.

By itself this is sufficient to restore the compressed mesh.
*/
Encoded_Mesh :: struct {
	vertex_codec: Vertex_Codec_Kind,
	symbols:      [dynamic]Operation,
	vertices:     [dynamic]Vector3,
	topology:     [dynamic]Topology_Entry,
	components:   [dynamic]Component_Info,
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

/******************************** STRUCT LIFETIMES ****************************/

/*
Initialize Encoded Mesh. If used with Encoder State (assumed usage) it can
self-attach to it (= set es.em).
*/
init_em :: proc(
	em: ^Encoded_Mesh,
	n_symbols: int = 0,
	n_vertices: int = 0,
	allocator := context.allocator,
	loc := #caller_location,
) {
	em.symbols = make([dynamic]Operation, 0, n_symbols, allocator, loc)
	em.vertices = make([dynamic]Vector3, 0, n_vertices, allocator, loc)
	em.topology = make([dynamic]Topology_Entry, 0, 0, allocator, loc)
	em.components = make([dynamic]Component_Info, 0, 0, allocator, loc)
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

/********************************** PROCEDURES ********************************/

/*
Decide which clers symbol is this situation.

Inputs:
- tip_is_new: tip vertex was not previously reached AND is not on hole
- right/left_done: r/l triangle already processed or doesn't exist (border)
*/
clers_symbol :: proc(tip_is_new, right_done, left_done: bool) -> Operation {
	switch {
	case tip_is_new:
		return .C
	case right_done && left_done:
		return .E
	case right_done:
		return .R
	case left_done:
		return .L
	case:
		return .S
	}
}

/*
Return the corner of triangle given by its tip corner and desired edge side.
*/
side_corner :: #force_inline proc(tip: ct.Corner, side: Side) -> ct.Corner {
	if side == .RIGHT {return ct.next(tip)} else {return ct.prev(tip)}
}
