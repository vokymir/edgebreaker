package edgebreaker

import "core:path/filepath"

write :: proc(em: Encoded_Mesh, filename: string) -> bool {
	switch filepath.ext(filename) {
	case ".simple.ebk":
		return write_file_simple(em, filename)
	case ".ebk":
		return write_file_binary(em, filename)
	case:
		return false
	}
}

@(private = "file")
write_file_simple :: proc(em: Encoded_Mesh, filename: string) -> bool {
	return true
}

@(private = "file")
write_file_binary :: proc(em: Encoded_Mesh, filename: string) -> bool {
	return false
}
