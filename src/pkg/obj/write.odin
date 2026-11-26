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
write_obj :: proc(sb: ^strings.Builder, m: Mesh) {
	buf: [64]byte // longest possible f32 in positional form is ~48 characters

	for p in m.positions {
		strings.write_byte(sb, 'v')
		for c in p {
			v := c
			if v == 0 {
				v = 0 // turns -0 into +0
			}
			strings.write_byte(sb, ' ')
			// The last argument is `flags`. Its default is {.Plus}, which would print
			// "+2.5" (the default exists only for backwards compatibility); nil gives "2.5".
			strings.write_string(sb, strconv.write_float(buf[:], f64(v), 'f', -1, 32))
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
