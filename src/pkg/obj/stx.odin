package obj

// STX reader.
//
// STX has no public specification. STX_FORMAT.md (next to this file) is the full description,
// with annotated hex dumps of a real file; this comment is the short version.
//
// The layout below was recovered by disassembling
// StxLoader.dll (namespace Pdm.Loaders, built from "BlueView50 ... SharpDX") and then
// checked by executing that DLL's own IL on synthetic files and comparing results.
// Treat the DLL as the specification; where it ignores something, so do we.
//
// All integers/floats are little-endian.
//
//   Header
//     i32   version              (ignored)
//     i64   buffer_pointer       absolute file offset of the geometry block
//     i64   <unused>             (ignored)
//
//   ... metadata blocks (ids, bounding box, colours, textures, ...) ...
//   Everything in there is irrelevant to geometry and is NOT parsed. The original
//   loader never takes geometry from this stream either, only from `buffer_pointer`.
//
//   Geometry block, found at `buffer_pointer`
//     i32   token                must be 18 (TOKEN_BUFFERDATA)
//     i32   block_size           (ignored)
//     i32   buffer_count
//     buffer_count times:
//       i32   byte_size          bytes that follow in this buffer, from `level` through the
//                                last index (observed on real files; the loader ignores it,
//                                and so do we)
//       f32   level              the loader keeps the buffer whose level == 1.0
//                                (inferred to be a level-of-detail value; if several
//                                buffers carry 1.0, the last one wins)
//       i32   vertex_count
//       vertex_count * { f32 x, f32 y, f32 z }
//       i32   face_count
//       u8    narrow             non-zero: indices are u16, zero: indices are u32
//       face_count * 3 * (u16 | u32)   indexed triangle list, 0-based
//
// Confirmed on real files (one inspected in depth; a batch of ~37,000 converted, of which
// only 6 were not convertible, see the last point):
//   - in the file inspected, the header pointer is the offset of the BUFFERDATA token, the last
//     block, ending exactly at end-of-file; the blocks before it are a token stream
//     (token i32, then usually i32 size + payload) containing a BOUNDINGBOX whose values equal
//     the decoded vertex extents;
//   - that file holds two buffers, levels 0.25 and 1.0 (1364 vs 1372 vertices): consistent with
//     `level` being a level of detail, though here the 0.25 buffer is barely coarser;
//   - the stored winding is already outward-facing in OBJ's right-handed convention: the
//     welded mesh is a closed, consistently oriented 2-manifold with positive signed volume.
//     Do NOT use `flip_z` alone; it mirrors the mesh and turns it inside out.
//   - some files carry no geometry (pointer 0, only thumbnail/metadata) -> `.No_Geometry`;
//     a few others are not STX at all (pointer garbage) -> `.Bad_Header`.
//
STX_TOKEN_BUFFER_DATA :: 18
STX_HEADER_SIZE :: 4 + 8 + 8

// Stx_Buffer describes one geometry buffer inside an STX file, without decoding it.
Stx_Buffer :: struct {
	level:        f32,
	vertex_count: int,
	face_count:   int,
	narrow:       bool, // true: 16-bit indices, false: 32-bit indices
	vertex_data:  int, // byte offset of the first vertex
	index_data:   int, // byte offset of the first index
}

// stx_scan lists every geometry buffer in `data`. It validates all counts against the
// file size, so hostile or truncated files cannot trigger huge allocations.
// The returned slice is owned by the caller: `delete(buffers, allocator)`.
stx_scan :: proc(data: []byte, allocator := context.allocator) -> (buffers: []Stx_Buffer, err: Error) {
	r := Reader{data = data}

	_ = read_i32(&r) // version
	pointer := read_i64(&r)
	_ = read_i64(&r) // second pointer, unused by the original loader
	if r.failed {
		return nil, .Truncated
	}
	if pointer == 0 {
		// Seen in real data: an STX holding only metadata and a thumbnail has no geometry
		// block, and its pointer is 0. That is a valid file, just not a convertible one.
		return nil, .No_Geometry
	}
	if pointer < 0 || pointer >= i64(len(data)) {
		return nil, .Bad_Header
	}

	r.pos = int(pointer)
	token := read_i32(&r)
	_ = read_i32(&r) // block size
	count := read_i32(&r)
	if r.failed {
		return nil, .Truncated
	}
	if token != STX_TOKEN_BUFFER_DATA {
		return nil, .No_Buffer_Data
	}
	if count < 0 {
		return nil, .Corrupt
	}

	list := make([dynamic]Stx_Buffer, allocator)
	defer if err != .None {
		delete(list)
	}

	for _ in 0 ..< int(count) {
		b: Stx_Buffer

		_ = read_i32(&r) // byte_size of this buffer; the original loader ignores it
		b.level = read_f32(&r)
		vertex_count := read_i32(&r)
		if r.failed {
			return nil, .Truncated
		}
		if vertex_count < 0 {
			return nil, .Corrupt
		}
		b.vertex_count = int(vertex_count)
		b.vertex_data = reader_skip(&r, i64(vertex_count) * 12)

		face_count := read_i32(&r)
		b.narrow = read_u8(&r) != 0
		if r.failed {
			return nil, .Truncated
		}
		if face_count < 0 {
			return nil, .Corrupt
		}
		b.face_count = int(face_count)
		index_size := 2 if b.narrow else 4
		b.index_data = reader_skip(&r, i64(face_count) * 3 * i64(index_size))
		if r.failed {
			return nil, .Truncated
		}

		append(&list, b)
	}

	return list[:], .None
}

// read_stx decodes one buffer of an STX file into a Mesh: the buffer whose level equals
// `level` (the original loader always used 1.0; if several match, the last one wins).
// The returned mesh is exactly what is stored; it is not welded or transformed.
// Free it with `mesh_destroy`.
read_stx :: proc(data: []byte, level: f32 = 1.0, allocator := context.allocator) -> (mesh: Mesh, err: Error) {
	buffers: []Stx_Buffer
	buffers, err = stx_scan(data, allocator)
	if err != .None {
		return {}, err
	}
	defer delete(buffers, allocator)

	chosen := -1
	for b, i in buffers {
		if b.level == level {
			chosen = i
		}
	}
	if chosen < 0 {
		return {}, .No_Matching_Buffer
	}

	return stx_decode(data, buffers[chosen], allocator)
}

@(private)
stx_decode :: proc(data: []byte, b: Stx_Buffer, allocator := context.allocator) -> (mesh: Mesh, err: Error) {
	positions := make([][3]f32, b.vertex_count, allocator)
	triangles := make([][3]u32, b.face_count, allocator)
	defer if err != .None {
		delete(positions, allocator)
		delete(triangles, allocator)
	}

	for i in 0 ..< b.vertex_count {
		at := b.vertex_data + i * 12
		for k in 0 ..< 3 {
			bits := le_u32(data[at + k * 4:])
			if (bits & 0x7F80_0000) == 0x7F80_0000 { // exponent all ones: NaN or infinity
				return {}, .Non_Finite
			}
			positions[i][k] = transmute(f32)bits
		}
	}

	index_size := 2 if b.narrow else 4
	for i in 0 ..< b.face_count {
		for k in 0 ..< 3 {
			at := b.index_data + (i * 3 + k) * index_size
			if b.narrow {
				triangles[i][k] = u32(le_u16(data[at:]))
			} else {
				triangles[i][k] = le_u32(data[at:])
			}
		}
	}
	if !indices_in_range(triangles, b.vertex_count) {
		return {}, .Bad_Index
	}

	return Mesh{positions = positions, triangles = triangles}, .None
}

// ---------------------------------------------------------------------------------------
// Bounds-checked little-endian reader. Reads past the end do not crash: they set `failed`
// and return zero, so callers can check once per section instead of once per field.

@(private = "file")
Reader :: struct {
	data:   []byte,
	pos:    int,
	failed: bool,
}

// reader_skip advances over `n` bytes and returns the offset where they started.
@(private = "file")
reader_skip :: proc(r: ^Reader, n: i64) -> int {
	start := r.pos
	if r.failed || n < 0 || n > i64(len(r.data) - r.pos) {
		r.failed = true
		return start
	}
	r.pos += int(n)
	return start
}

@(private = "file")
read_u8 :: proc(r: ^Reader) -> u8 {
	at := reader_skip(r, 1)
	if r.failed {
		return 0
	}
	return r.data[at]
}

@(private = "file")
read_i32 :: proc(r: ^Reader) -> i32 {
	at := reader_skip(r, 4)
	if r.failed {
		return 0
	}
	return transmute(i32)le_u32(r.data[at:])
}

@(private = "file")
read_i64 :: proc(r: ^Reader) -> i64 {
	at := reader_skip(r, 8)
	if r.failed {
		return 0
	}
	lo := u64(le_u32(r.data[at:]))
	hi := u64(le_u32(r.data[at + 4:]))
	return transmute(i64)(lo | (hi << 32))
}

@(private = "file")
read_f32 :: proc(r: ^Reader) -> f32 {
	at := reader_skip(r, 4)
	if r.failed {
		return 0
	}
	return transmute(f32)le_u32(r.data[at:])
}

@(private = "file")
le_u16 :: proc(b: []byte) -> u16 {
	return u16(b[0]) | (u16(b[1]) << 8)
}

@(private = "file")
le_u32 :: proc(b: []byte) -> u32 {
	return u32(b[0]) | (u32(b[1]) << 8) | (u32(b[2]) << 16) | (u32(b[3]) << 24)
}
