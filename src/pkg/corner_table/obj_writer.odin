package corner_table

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

/*
Save triangle mesh to disk @ <filepath> from the in-memory Corner_Table 
representation.

Supported formats to save to:
- [OBJ](https://en.wikipedia.org/wiki/Wavefront_.obj_file)

Inputs:
- ct: Corner_Table triangle mesh representation
- filepath: the path to file on disk
- allocator: allocator used for temporary structures (unused after return)
- loc: caller location

Returns:
- ok: false on invalid file access 
*/
save :: proc {
	save_ct_to_obj,
}

@(private)
save_ct_to_obj :: proc(
	ct: Corner_Table,
	filepath: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	ok := false,
) {
	f, err := os.create(filepath)
	if err != os.ERROR_NONE {
		return
	}
	defer os.close(f)

	s := strings.builder_make(allocator, loc)
	defer strings.builder_destroy(&s)

	for v in ct.pos {
		fmt.sbprintln(&s, "v", v.x, v.y, v.z)
	}

	triplets := slice.reinterpret([][3]Vertex, ct.tris[:])
	for t in triplets {
		// +1 is important as .obj is 1-indexed
		fmt.sbprintln(&s, "f", t[0] + 1, t[1] + 1, t[2] + 1)
	}

	if _, err := os.write_string(f, strings.to_string(s)); err != os.ERROR_NONE {
		return
	}

	ok = true
	return
}
