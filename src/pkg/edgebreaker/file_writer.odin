package edgebreaker

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

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

@(private = "file")
write_file_simple :: proc(
	em: Encoded_Mesh,
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	f, err := os.create(filename)
	if err != os.ERROR_NONE {
		log.debug("Cannot create output file:", err)
		return false
	}
	defer os.close(f)

	sb := strings.builder_make(allocator, loc)
	defer strings.builder_destroy(&sb)

	fmt.sbprintln(&sb, "predictor:", em.predictor)

	fmt.sbprintln(&sb, "symbols:")
	for sym in em.symbols {
		fmt.sbprint(&sb, sym)
	}
	fmt.sbprintln(&sb)

	fmt.sbprintln(&sb, "topology:")
	for top in em.topology {
		fmt.sbprintln(&sb, top.s_step, top.arrival_step, top.arrival_side, top.hole_len)
	}

	fmt.sbprintln(&sb, "components:")
	for comp in em.components {
		fmt.sbprintln(&sb, comp.outer_boundary)
	}

	fmt.sbprintln(&sb, "vertices:")
	for v in em.vertices {
		fmt.sbprintln(&sb, v.x, v.y, v.z)
	}

	_, err = os.write_string(f, strings.to_string(sb))
	if err != os.ERROR_NONE {
		log.debug("Couldn't write string into file:", err)
		return false
	}

	return true
}

@(private = "file")
write_file_binary :: proc(em: Encoded_Mesh, filename: string) -> bool {
	return false
}
