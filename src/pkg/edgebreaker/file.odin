package edgebreaker

import "core:path/filepath"

/*
Public API of FILE handling.
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
