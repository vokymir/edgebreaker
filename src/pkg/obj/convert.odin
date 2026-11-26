package obj

import "core:strings"

// Package obj converts other mesh formats to Wavefront OBJ.
//
//   reader (per format)  ->  Mesh  ->  optional clean-up  ->  write_obj
//
// Adding a format (e.g. PLY) takes three edits:
//   1. add a value to `Format` and teach `detect_format` its file extension;
//   2. write `read_ply :: proc(data: []byte, allocator) -> (Mesh, Error)` in ply.odin.
//      It must return a valid Mesh (see `indices_in_range`) or an Error, never partial data;
//   3. add the matching `case` in `convert` (the compiler flags it until you do).

Error :: enum {
	None,
	Read_Failed, // input file could not be read
	Write_Failed, // output file could not be written
	Unsupported_Format, // unknown file extension
	Truncated, // file ends before its own headers/counts say it should
	Bad_Header, // header pointer outside the file: not an STX at all, or corrupt
	No_Geometry, // a valid STX that simply contains no 3D data (metadata and thumbnail only)
	No_Buffer_Data, // pointer does not lead to a geometry block
	No_Matching_Buffer, // no geometry buffer has the requested level
	Corrupt, // negative count or similar nonsense
	Bad_Index, // triangle refers to a vertex that does not exist
	Non_Finite, // NaN or infinity in a vertex coordinate
}

error_message :: proc(e: Error) -> string {
	switch e {
	case .None:
		return "no error"
	case .Read_Failed:
		return "could not read input file"
	case .Write_Failed:
		return "could not write output file"
	case .Unsupported_Format:
		return "unsupported input format (by file extension)"
	case .Truncated:
		return "file is truncated"
	case .Bad_Header:
		return "header pointer lies outside the file (not an STX file, or corrupt)"
	case .No_Geometry:
		return "file contains no 3D geometry (header geometry pointer is 0)"
	case .No_Buffer_Data:
		return "header pointer does not lead to a geometry block (corrupt file)"
	case .No_Matching_Buffer:
		return "no geometry buffer has the requested level (use --list to see what the file contains)"
	case .Corrupt:
		return "file is corrupt (invalid count)"
	case .Bad_Index:
		return "a triangle refers to a vertex that does not exist"
	case .Non_Finite:
		return "a vertex coordinate is NaN or infinite"
	}
	return "unknown error"
}

// Options tunes a conversion. The zero value, `Options{}`, is the recommended default.
Options :: struct {
	keep_duplicates: bool, // by default identical vertices are welded and unused ones dropped (see `mesh_weld`)
	flip_z:          bool, // negate Z (what the old C# importer always did)
	reverse_winding: bool, // swap two indices per triangle
	stx_level:       Maybe(f32), // which STX geometry buffer to take; nil means 1.0, as in the original loader
}

Format :: enum {
	Unknown,
	STX,
}

// detect_format picks the reader from the file extension (case-insensitive).
detect_format :: proc(path: string) -> Format {
	if has_extension(path, ".stx") {
		return .STX
	}
	return .Unknown
}

// convert reads a mesh in `format` from `data`, applies `opts`, and appends OBJ text to `sb`.
convert :: proc(
	format: Format,
	data: []byte,
	sb: ^strings.Builder,
	opts := Options{},
	allocator := context.allocator,
) -> Error {
	mesh: Mesh
	err: Error

	switch format {
	case .STX:
		mesh, err = read_stx(data, opts.stx_level.? or_else 1.0, allocator)
	case .Unknown:
		return .Unsupported_Format
	}
	if err != .None {
		return err
	}
	defer mesh_destroy(&mesh, allocator)

	if !opts.keep_duplicates {
		mesh_weld(&mesh, allocator)
	}
	if opts.flip_z {
		mesh_flip_z(&mesh)
	}
	if opts.reverse_winding {
		mesh_reverse_winding(&mesh)
	}

	write_obj(sb, mesh)
	return .None
}

// convert_file converts the file at `src` and writes the OBJ to `dst`.
// The reader is chosen from the extension of `src`.
convert_file :: proc(src, dst: string, opts := Options{}, allocator := context.allocator) -> Error {
	format := detect_format(src)
	if format == .Unknown {
		return .Unsupported_Format
	}

	data, read_ok := read_file(src, allocator)
	if !read_ok {
		return .Read_Failed
	}
	defer delete(data, allocator)

	sb: strings.Builder
	strings.builder_init(&sb, allocator)
	defer strings.builder_destroy(&sb)

	if err := convert(format, data, &sb, opts, allocator); err != .None {
		return err
	}

	if !write_file(dst, sb.buf[:]) {
		return .Write_Failed
	}
	return .None
}

@(private = "file")
has_extension :: proc(path, ext: string) -> bool {
	if len(path) < len(ext) {
		return false
	}
	return strings.equal_fold(path[len(path) - len(ext):], ext)
}
