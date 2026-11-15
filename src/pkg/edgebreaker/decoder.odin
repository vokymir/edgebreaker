package edgebreaker

import ct "../corner_table"

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
decode :: proc(
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
