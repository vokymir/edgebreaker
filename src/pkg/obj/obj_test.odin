package obj

// Run with:  odin test src/obj
//
// The tests build small STX files in memory (layout documented in stx.odin) and compare
// the produced OBJ text against expectations computed independently of this code.

import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------------------
// Synthetic STX files

@(private = "file")
Test_Buffer :: struct {
	level:     f32,
	positions: [][3]f32,
	triangles: [][3]u32,
	flag:      u8, // the "narrow" byte: non-zero = 16-bit indices, 0 = 32-bit indices
}

@(private = "file")
put_u8 :: proc(b: ^[dynamic]byte, v: u8) {
	append(b, v)
}

@(private = "file")
put_u16 :: proc(b: ^[dynamic]byte, v: u16) {
	append(b, byte(v), byte(v >> 8))
}

@(private = "file")
put_u32 :: proc(b: ^[dynamic]byte, v: u32) {
	append(b, byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24))
}

@(private = "file")
put_i32 :: proc(b: ^[dynamic]byte, v: i32) {
	put_u32(b, transmute(u32)v)
}

@(private = "file")
put_i64 :: proc(b: ^[dynamic]byte, v: i64) {
	bits := transmute(u64)v
	put_u32(b, u32(bits))
	put_u32(b, u32(bits >> 32))
}

@(private = "file")
put_f32 :: proc(b: ^[dynamic]byte, v: f32) {
	put_u32(b, transmute(u32)v)
}

// build_stx lays out: header, one ignorable metadata block, then the geometry block.
// Offsets used by the corruption tests below: pointer at byte 4, geometry token at byte 32,
// first buffer's vertex_count at byte 52.
@(private = "file")
build_stx :: proc(buffers: []Test_Buffer) -> []byte {
	payload: [dynamic]byte
	defer delete(payload)

	put_i32(&payload, i32(len(buffers)))
	for buf in buffers {
		put_i32(&payload, 0) // unused
		put_f32(&payload, buf.level)
		put_i32(&payload, i32(len(buf.positions)))
		for p in buf.positions {
			for c in p {
				put_f32(&payload, c)
			}
		}
		put_i32(&payload, i32(len(buf.triangles)))
		put_u8(&payload, buf.flag)
		for t in buf.triangles {
			for i in t {
				if buf.flag != 0 {
					put_u16(&payload, u16(i))
				} else {
					put_u32(&payload, i)
				}
			}
		}
	}

	file: [dynamic]byte
	put_i32(&file, 2) // version
	put_i64(&file, STX_HEADER_SIZE + 12) // geometry block comes after one 12-byte metadata block
	put_i64(&file, 0)
	put_i32(&file, 3) // metadata: a made-up block the reader must skip
	put_i32(&file, 4)
	put_i32(&file, 0x1234_5678)
	put_i32(&file, STX_TOKEN_BUFFER_DATA)
	put_i32(&file, i32(len(payload)))
	append(&file, ..payload[:])
	return file[:]
}

@(private = "file")
expect_obj :: proc(t: ^testing.T, data: []byte, opts: Options, expected: string, loc := #caller_location) {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	err := convert(.STX, data, &sb, opts)
	testing.expect_value(t, err, Error.None, loc = loc)
	testing.expect_value(t, strings.to_string(sb), expected, loc = loc)
}

@(private = "file")
expect_error :: proc(t: ^testing.T, data: []byte, opts: Options, expected: Error, loc := #caller_location) {
	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)

	testing.expect_value(t, convert(.STX, data, &sb, opts), expected, loc = loc)
}

// ---------------------------------------------------------------------------------------
// Shared fixtures

// Real files from the project's data set (testdata/). The STX is a washer: after welding a
// closed, consistently oriented genus-1 mesh with 366 vertices and 732 triangles. The OBJ next
// to it was produced by an independent decoder/formatter, not by this package.
@(private = "file")
REAL_STX :: #load("testdata/000000_1_3D.STX")
@(private = "file")
REAL_OBJ :: #load("testdata/000000_1_3D.obj", string)
// A valid STX that holds only metadata and a JPEG thumbnail: header pointer is 0.
@(private = "file")
THUMBNAIL_ONLY_STX :: #load("testdata/601982_1_3D.STX")

@(private = "file")
TET_POSITIONS := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
@(private = "file")
TET_TRIANGLES := [][3]u32{{0, 2, 1}, {0, 1, 3}, {1, 2, 3}, {0, 3, 2}}

// ---------------------------------------------------------------------------------------
// Tests

@(test)
stx_tetrahedron_welded :: proc(t: ^testing.T) {
	data := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1}})
	defer delete(data)

	// welding renumbers vertices in order of first use
	expect_obj(
		t,
		data,
		Options{},
		"v 0 0 0\nv 0 1 0\nv 1 0 0\nv 0 0 1\n" + "f 1 2 3\nf 1 3 4\nf 3 2 4\nf 1 4 2\n",
	)
}

@(test)
stx_tetrahedron_as_stored_with_32bit_indices :: proc(t: ^testing.T) {
	data := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 0}})
	defer delete(data)

	expect_obj(
		t,
		data,
		Options{keep_duplicates = true},
		"v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\n" + "f 1 3 2\nf 1 2 4\nf 2 3 4\nf 1 4 3\n",
	)
}

@(test)
stx_any_nonzero_flag_means_16bit_indices :: proc(t: ^testing.T) {
	// the original loader uses BinaryReader.ReadBoolean, which treats every non-zero byte as true
	data := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 2}})
	defer delete(data)

	expect_obj(
		t,
		data,
		Options{keep_duplicates = true},
		"v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 1\n" + "f 1 3 2\nf 1 2 4\nf 2 3 4\nf 1 4 3\n",
	)
}

@(test)
stx_weld_merges_duplicates_and_drops_unused_vertices :: proc(t: ^testing.T) {
	positions := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 0}, {9, 9, 9}, {1, 0, 0}, {0, 1, 0}}
	triangles := [][3]u32{{0, 1, 2}, {3, 5, 6}}
	data := build_stx([]Test_Buffer{{level = 1, positions = positions, triangles = triangles, flag = 1}})
	defer delete(data)

	expect_obj(t, data, Options{}, "v 0 0 0\nv 1 0 0\nv 0 1 0\n" + "f 1 2 3\nf 1 2 3\n")
	expect_obj(
		t,
		data,
		Options{keep_duplicates = true},
		"v 0 0 0\nv 1 0 0\nv 0 1 0\nv 0 0 0\nv 9 9 9\nv 1 0 0\nv 0 1 0\n" + "f 1 2 3\nf 4 6 7\n",
	)
}

@(test)
stx_weld_treats_negative_zero_as_zero :: proc(t: ^testing.T) {
	negative_zero := transmute(f32)u32(0x8000_0000)
	positions := [][3]f32{{0, 0, 0}, {negative_zero, 0, 0}, {1, 0, 0}}
	data := build_stx([]Test_Buffer{{level = 1, positions = positions, triangles = [][3]u32{{0, 1, 2}}, flag = 1}})
	defer delete(data)

	expect_obj(t, data, Options{}, "v 0 0 0\nv 1 0 0\n" + "f 1 1 2\n")
}

@(test)
stx_floats_print_shortest_and_never_in_exponent_form :: proc(t: ^testing.T) {
	negative_zero := transmute(f32)u32(0x8000_0000)
	positions := [][3]f32{{0.1, -2.25, 1.5}, {1e-7, 0, 1.5e10}, {3, 4, negative_zero}}
	data := build_stx([]Test_Buffer{{level = 1, positions = positions, triangles = [][3]u32{{0, 1, 2}}, flag = 1}})
	defer delete(data)

	expect_obj(t, data, Options{}, "v 0.1 -2.25 1.5\nv 0.0000001 0 15000000000\nv 3 4 0\n" + "f 1 2 3\n")
}

@(test)
stx_flip_z_and_winding :: proc(t: ^testing.T) {
	data := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1}})
	defer delete(data)

	expect_obj(
		t,
		data,
		Options{flip_z = true, reverse_winding = true},
		"v 0 0 0\nv 0 1 0\nv 1 0 0\nv 0 0 -1\n" + "f 1 3 2\nf 1 4 3\nf 3 4 2\nf 1 2 4\n",
	)
}

@(test)
stx_selects_the_buffer_by_level :: proc(t: ^testing.T) {
	coarse_positions := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	data := build_stx(
		[]Test_Buffer {
			{level = 0.25, positions = coarse_positions, triangles = [][3]u32{{0, 1, 2}}, flag = 1},
			{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1},
		},
	)
	defer delete(data)

	tet_welded := "v 0 0 0\nv 0 1 0\nv 1 0 0\nv 0 0 1\n" + "f 1 2 3\nf 1 3 4\nf 3 2 4\nf 1 4 2\n"
	expect_obj(t, data, Options{}, tet_welded) // default: level 1
	expect_obj(t, data, Options{stx_level = f32(0.25)}, "v 0 0 0\nv 1 0 0\nv 0 1 0\n" + "f 1 2 3\n")
	expect_error(t, data, Options{stx_level = f32(0.5)}, .No_Matching_Buffer)
}

@(test)
stx_last_buffer_wins_when_levels_tie :: proc(t: ^testing.T) {
	one := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
	data := build_stx(
		[]Test_Buffer {
			{level = 1, positions = one, triangles = [][3]u32{{0, 1, 2}}, flag = 1},
			{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1},
		},
	)
	defer delete(data)

	expect_obj(
		t,
		data,
		Options{},
		"v 0 0 0\nv 0 1 0\nv 1 0 0\nv 0 0 1\n" + "f 1 2 3\nf 1 3 4\nf 3 2 4\nf 1 4 2\n",
	)
}

@(test)
stx_scan_reports_buffers :: proc(t: ^testing.T) {
	data := build_stx(
		[]Test_Buffer {
			{level = 0.5, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1},
			{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES[:2], flag = 0},
		},
	)
	defer delete(data)

	buffers, err := stx_scan(data)
	defer delete(buffers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(buffers), 2)
	if len(buffers) == 2 {
		testing.expect_value(t, buffers[0].level, f32(0.5))
		testing.expect_value(t, buffers[0].vertex_count, 4)
		testing.expect_value(t, buffers[0].face_count, 4)
		testing.expect_value(t, buffers[0].narrow, true)
		testing.expect_value(t, buffers[1].level, f32(1))
		testing.expect_value(t, buffers[1].face_count, 2)
		testing.expect_value(t, buffers[1].narrow, false)
	}
}

@(test)
stx_rejects_bad_files :: proc(t: ^testing.T) {
	good := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = TET_TRIANGLES, flag = 1}})
	defer delete(good)

	// cut off inside the header, and inside the last index array
	expect_error(t, good[:10], Options{}, .Truncated)
	expect_error(t, good[:len(good) - 3], Options{}, .Truncated)

	// pointer outside the file
	{
		data := clone_bytes(good)
		defer delete(data)
		pointer := i64(len(data)) + 100
		for k in 0 ..< 8 {
			data[4 + k] = byte(u64(pointer) >> u64(8 * k))
		}
		expect_error(t, data, Options{}, .Bad_Header)
	}

	// pointer leads somewhere that is not a geometry block
	{
		data := clone_bytes(good)
		defer delete(data)
		data[32] = 99
		expect_error(t, data, Options{}, .No_Buffer_Data)
	}

	// absurd vertex count must fail cleanly instead of allocating gigabytes
	{
		data := clone_bytes(good)
		defer delete(data)
		data[52], data[53], data[54], data[55] = 0xFF, 0xFF, 0xFF, 0x7F
		expect_error(t, data, Options{}, .Truncated)
	}

	// triangle refers to vertex 4, but only 0..3 exist
	{
		data := build_stx([]Test_Buffer{{level = 1, positions = TET_POSITIONS, triangles = [][3]u32{{0, 1, 4}}, flag = 1}})
		defer delete(data)
		expect_error(t, data, Options{}, .Bad_Index)
	}

	// infinity in a coordinate
	{
		infinity := transmute(f32)u32(0x7F80_0000)
		data := build_stx([]Test_Buffer{{level = 1, positions = [][3]f32{{0, 0, infinity}}, triangles = nil, flag = 1}})
		defer delete(data)
		expect_error(t, data, Options{}, .Non_Finite)
	}
}

@(test)
real_file_converts_to_the_expected_obj :: proc(t: ^testing.T) {
	expect_obj(t, REAL_STX, Options{}, REAL_OBJ)
}

@(test)
real_file_lists_both_buffers :: proc(t: ^testing.T) {
	buffers, err := stx_scan(REAL_STX)
	defer delete(buffers)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, len(buffers), 2)
	if len(buffers) == 2 {
		testing.expect_value(t, buffers[0].level, f32(0.25))
		testing.expect_value(t, buffers[0].vertex_count, 1364)
		testing.expect_value(t, buffers[0].face_count, 726)
		testing.expect_value(t, buffers[1].level, f32(1))
		testing.expect_value(t, buffers[1].vertex_count, 1372)
		testing.expect_value(t, buffers[1].face_count, 732)
		testing.expect_value(t, buffers[1].narrow, true)
	}
}

@(test)
real_file_without_geometry_is_reported_as_such :: proc(t: ^testing.T) {
	expect_error(t, THUMBNAIL_ONLY_STX, Options{}, .No_Geometry)
}

@(test)
header_pointer_zero_means_no_geometry :: proc(t: ^testing.T) {
	data := make([]byte, 64)
	defer delete(data)
	data[0], data[1], data[2] = 0x47, 0x60, 0x03 // version 0x00036047; both pointers stay 0
	expect_error(t, data, Options{}, .No_Geometry)
}

@(test)
file_that_is_not_an_stx_is_rejected :: proc(t: ^testing.T) {
	// First 20 bytes of a real "STX" in the data set that was actually a fragment of a
	// Windows driver binary: the header pointer decodes to a negative number.
	head := [20]byte{
		0x08, 0x49, 0x89, 0x85, 0x18, 0x01, 0x00, 0x00, 0xe9, 0xc7,
		0xf3, 0xff, 0xff, 0x0b, 0xcb, 0x41, 0x89, 0x8d, 0xac, 0x01,
	}
	data := make([]byte, 256)
	defer delete(data)
	copy(data, head[:])
	expect_error(t, data, Options{}, .Bad_Header)
}

@(test)
format_is_detected_from_the_extension :: proc(t: ^testing.T) {
	testing.expect_value(t, detect_format("scan.stx"), Format.STX)
	testing.expect_value(t, detect_format("dir/SCAN.STX"), Format.STX)
	testing.expect_value(t, detect_format("scan.obj"), Format.Unknown)
	testing.expect_value(t, detect_format("stx"), Format.Unknown)
}

@(private = "file")
clone_bytes :: proc(b: []byte) -> []byte {
	out := make([]byte, len(b))
	copy(out, b)
	return out
}
