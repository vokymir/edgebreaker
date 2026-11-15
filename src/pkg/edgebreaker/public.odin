package edgebreaker

import ct "../corner_table"
import "core:path/filepath"

/*******************************************************************************
*                                Alias                                         *
*******************************************************************************/

Vector3 :: ct.Vec3

/*******************************************************************************
*                                Enums                                         *
*******************************************************************************/

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


/*******************************************************************************
*                                Structs                                       *
*******************************************************************************/

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

/*******************************************************************************
*                                Struct lifetimes                              *
*******************************************************************************/

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
	free(em)
}

/*******************************************************************************
*                                Encoder                                       *
*******************************************************************************/

compress :: proc {
	compress_internal,
}

/*******************************************************************************
*                                Decoder                                       *
*******************************************************************************/

/*
Notes on adding new decoder kinds: add it to decoder kind and compiler forces to
fill information in other places
*/

Decoder_Kind :: enum u8 {
	WRAP_AND_ZIP,
	SPIRALE_REVERSI,
}

Decoder_Info :: struct {
	summary: string,
	notes:   string,
}

/*
Human readable description for CLI.
*/
decoder_info :: proc(k: Decoder_Kind) -> Decoder_Info {
	switch k {
	case .WRAP_AND_ZIP:
		return {
			summary = "forward decoder, connectivity built by wrapping and zipping",
			notes = "Reads the clers string from the start and glues the free edges as soon as their pair appears.",
		}
	case .SPIRALE_REVERSI:
		return {
			summary = "reverse decoder, clers string read backwards",
			notes = "Triangles are attached to already known successors and no zipping is needed.",
		}
	}
	return {}
}

/*
Decode the mesh with the selected decoder.

Inputs:
- em: encoded mesh
- t: initialized (empty) corner table to be filled
*/
decompress :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	kind := Decoder_Kind.WRAP_AND_ZIP,
	allocator := context.allocator,
	loc := #caller_location,
) {
	switch kind {
	case .WRAP_AND_ZIP:
		decode_wrap_and_zip(em, t, allocator, loc)
	case .SPIRALE_REVERSI:
		decode_spirale_reversi(em, t, allocator, loc)
	}
}

/*******************************************************************************
*                                File handling                                 *
*******************************************************************************/

/*
Write encoded mesh into file.
*/
write :: proc(
	em: Encoded_Mesh,
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	switch filepath.long_ext(filename) {
	case ".simple.ebk":
		return write_file_simple(em, filename, allocator, loc)
	case ".ebk":
		return write_file_binary(em, filename)
	case:
		return false
	}
}

/*
Read encoded mesh from file.

*The caller must free the Encoded Mesh.*

*/
@(require_results)
read :: proc(
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	^Encoded_Mesh,
	bool,
) {
	switch filepath.long_ext(filename) {
	case ".simple.ebk":
		return read_file_simple(filename, allocator, loc), true
	case ".ebk":
		return read_file_binary(filename), true
	case:
		return nil, false
	}
}

/*******************************************************************************
*                                Vertex codec                                  *
*******************************************************************************/

Vertex_Codec_Kind :: enum u8 {
	RAW, // absolute positions
	DELTA_PARALLELOGRAM, // delta on loops, parallelogram on tips
}

Vertex_Codec_Info :: struct {
	summary: string,
	notes:   string,
}

/*
Human readable description of every codec for CLI.
*/
vertex_codec_info :: proc(k: Vertex_Codec_Kind) -> Vertex_Codec_Info {
	switch k {
	case .RAW:
		return {
			summary = "absolute positions, no prediction",
			notes = "Every position is stored as is. Baseline. Good for debugging. Nothing is gained from the mesh regularity.",
		}
	case .DELTA_PARALLELOGRAM:
		return {
			summary = "parallelogram prediction inside, delta on boundaries and holes",
			notes = "Interior vertices store the error of the parallelogram prediction (gs + ge - opposite), boundary vertices store the difference to the previous one. Best on smooth meshes.",
		}
	}
	return {}
}
