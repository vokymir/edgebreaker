package obj

// Mesh is the common currency of this package: every reader (STX today, PLY later)
// produces one, and the OBJ writer consumes one.
//
// Invariant: every index in `triangles` is < len(positions). Readers must guarantee
// this before returning (see `indices_in_range`).
Mesh :: struct {
	positions: [][3]f32,
	triangles: [][3]u32, // 0-based indices into `positions`
}

mesh_destroy :: proc(m: ^Mesh, allocator := context.allocator) {
	delete(m.positions, allocator)
	delete(m.triangles, allocator)
	m^ = {}
}

// indices_in_range reports whether every triangle index addresses one of `vertex_count` vertices.
indices_in_range :: proc(triangles: [][3]u32, vertex_count: int) -> bool {
	for t in triangles {
		for i in t {
			if int(i) >= vertex_count {
				return false
			}
		}
	}
	return true
}

// mesh_weld merges vertices whose coordinates are bit-for-bit identical (-0 and +0 count
// as equal) and drops vertices that no triangle uses. Surviving vertices are numbered in
// order of first use by the triangle list.
//
// No tolerance is applied: STX stores float32 positions, and duplicates that exist only
// because the file repeats a vertex are bit-identical. Welding never moves a vertex.
mesh_weld :: proc(m: ^Mesh, allocator := context.allocator) {
	UNSET :: max(u32)

	remap := make([]u32, len(m.positions), allocator)
	defer delete(remap, allocator)
	for &r in remap {
		r = UNSET
	}

	seen := make(map[[3]u32]u32, len(m.positions), allocator)
	defer delete(seen)

	out := make([dynamic][3]f32, 0, len(m.positions), allocator)

	for &tri in m.triangles {
		for k in 0 ..< 3 {
			old := tri[k]
			if remap[old] == UNSET {
				p := m.positions[old]
				key := [3]u32{position_bits(p[0]), position_bits(p[1]), position_bits(p[2])}
				if found, ok := seen[key]; ok {
					remap[old] = found
				} else {
					fresh := u32(len(out))
					append(&out, p)
					seen[key] = fresh
					remap[old] = fresh
				}
			}
			tri[k] = remap[old]
		}
	}

	delete(m.positions, allocator)
	m.positions = out[:]
}

// mesh_flip_z negates every Z coordinate (mirrors the mesh). Winding is left untouched;
// combine with `mesh_reverse_winding` if the mirrored mesh must keep outward-facing normals.
mesh_flip_z :: proc(m: ^Mesh) {
	for &p in m.positions {
		p[2] = 0 - p[2] // `0 - z` rather than `-z`, so z == 0 stays +0 instead of becoming -0
	}
}

// mesh_reverse_winding swaps two indices of every triangle, flipping its orientation.
mesh_reverse_winding :: proc(m: ^Mesh) {
	for &t in m.triangles {
		t[1], t[2] = t[2], t[1]
	}
}

@(private = "file")
position_bits :: proc(x: f32) -> u32 {
	if x == 0 {
		return 0 // -0 and +0 are the same position
	}
	return transmute(u32)x
}
