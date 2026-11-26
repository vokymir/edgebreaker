package obj

import "core:strconv"
import "core:strings"

// write_obj appends `m` to `sb` as Wavefront OBJ text.
//
// The output is deliberately minimal: only `v` and `f` lines, no comments, normals,
// texture coordinates or groups. Face indices are 1-based, as OBJ requires.
//
// Coordinates are printed in the shortest decimal form that reads back as the exact
// same float32, and never in exponent notation (hand-written OBJ parsers often choke on it).
// Examples: 0   2.5   -11.99463   0.0000001   15000000000
write_obj :: proc(sb: ^strings.Builder, m: Mesh) {
	buf: [32]byte // a u32 index has at most 10 digits

	for p in m.positions {
		strings.write_byte(sb, 'v')
		for c in p {
			v := c
			if v == 0 {
				v = 0 // turns -0 into +0
			}
			strings.write_byte(sb, ' ')
			// strings.write_float writes straight into the builder and, unlike
			// strconv.write_float (whose default flags are {.Plus}), prints "2.5", not "+2.5",
			// because its `always_signed` parameter defaults to false.
			strings.write_float(sb, f64(v), 'f', -1, 32)
		}
		strings.write_byte(sb, '\n')
	}

	for t in m.triangles {
		strings.write_byte(sb, 'f')
		for i in t {
			strings.write_byte(sb, ' ')
			strings.write_string(sb, strconv.write_uint(buf[:], u64(i) + 1, 10))
		}
		strings.write_byte(sb, '\n')
	}
}
