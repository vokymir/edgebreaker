package main

// objconv: convert mesh files to Wavefront OBJ using package obj.
//
// Usage:
//   objconv scan1.stx scan2.stx
//   objconv ./scans
//   objconv ./scans ./more_scans
//
// Directories are searched recursively for .stx files.
//
// Options:
//   -o, --out <file>     output path (only valid with exactly one input file)
//   --no-weld            keep vertices exactly as stored
//   --flip-z             negate Z (mirrors the mesh; inside-out unless combined with --flip-winding)
//   --flip-winding       reverse the orientation of every triangle
//   --level <number>     STX geometry buffer to take (default 1)
//   --list               only print geometry buffers found in each STX file

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import obj "../../pkg/obj"

main :: proc() {
	opts: obj.Options
	inputs: [dynamic]string
	files: [dynamic]string
	invalid_inputs: [dynamic]string
	out_path: string
	list_only := false

	args := os.args[1:]

	for i := 0; i < len(args); i += 1 {
		switch arg := args[i]; arg {
		case "-h", "--help":
			usage()
			os.exit(0)

		case "--no-weld":
			opts.keep_duplicates = true

		case "--flip-z":
			opts.flip_z = true

		case "--flip-winding":
			opts.reverse_winding = true

		case "--list":
			list_only = true

		case "-o", "--out":
			i += 1
			if i >= len(args) {
				die("%s needs a value", arg)
			}
			out_path = args[i]

		case "--level":
			i += 1
			if i >= len(args) {
				die("%s needs a value", arg)
			}

			level, ok := strconv.parse_f32(args[i])
			if !ok {
				die("--level: %q is not a number", args[i])
			}
			opts.stx_level = level

		case:
			if strings.has_prefix(arg, "-") {
				die("unknown option %s (try --help)", arg)
			}
			append(&inputs, arg)
		}
	}

	if len(inputs) == 0 {
		usage()
		os.exit(2)
	}

	// Expand directories into individual STX files.
	for input in inputs {
		info, err := os.stat(input, context.allocator)
		if err != nil {
			fmt.eprintfln("Cannot access %s: %v", input, err)
			append(&invalid_inputs, input)
			continue
		}

		is_directory := info.type == .Directory
		os.file_info_delete(info, context.allocator)

		if is_directory {
			collect_stx_files(input, &files)
		} else if is_stx_file(input) {
			append(&files, input)
		} else {
			append(&invalid_inputs, input)
		}
	}

	// Report invalid input files together.
	if len(invalid_inputs) > 0 {
		fmt.eprintfln(
			"Unsupported input extension / inaccessible input: %d file(s)",
			len(invalid_inputs),
		)

		for path in invalid_inputs {
			fmt.eprintfln("  %s", path)
		}
		fmt.println("")
	}

	if len(files) == 0 {
		fmt.eprintln("No STX files found.")
		os.exit(1)
	}

	if out_path != "" && (len(files) != 1 || len(inputs) != 1) {
		die("-o/--out works with exactly one input STX file")
	}

	passed := 0
	skipped := 0 // valid STX files that simply contain no 3D geometry
	failed := 0

	// Convert or list every discovered STX file.
	for input in files {
		err: obj.Error
		if list_only {
			err = list_buffers(input)
		} else {
			output := out_path if out_path != "" else obj_path_for(input)
			err = obj.convert_file(input, output, opts)
			// if err == .None { fmt.printfln("[ OK ] %s -> %s", input, output) }
		}

		if err == .None {
			passed += 1
		} else if err == .No_Geometry {
			// Not an error in the file: it is a thumbnail/metadata-only item.
			fmt.eprintfln("[SKIP] %s: %s", input, obj.error_message(err))
			skipped += 1
		} else {
			fmt.eprintfln("[FAIL] %s: %s", input, obj.error_message(err))
			failed += 1
		}
	}

	// Final statistics.
	fmt.println("")
	fmt.println("========== Conversion Summary ==========")
	fmt.printfln("Total STX files:       %d", passed + skipped + failed)
	fmt.printfln("Passed:                %d", passed)
	fmt.printfln("Skipped (no geometry): %d", skipped)
	fmt.printfln("Failed conversions:    %d", failed)
	fmt.printfln("Invalid input files:   %d", len(invalid_inputs))

	if failed > 0 || len(invalid_inputs) > 0 {
		fmt.println("")
		fmt.println("Some files were not processed successfully.")
		os.exit(1)
	}

	if skipped > 0 {
		fmt.printfln(
			"All files with 3D geometry were processed; %d file(s) had none (see [SKIP] lines).",
			skipped,
		)
	} else {
		fmt.println("All files converted successfully.")
	}
}

// Check the final extension, case-insensitively.
// Accepts .stx, .3D.stx, .anything.stx, etc.
is_stx_file :: proc(path: string) -> bool {
	return strings.equal_fold(os.ext(path), ".stx")
}

// Recursively collect all STX files in a directory.
collect_stx_files :: proc(dir: string, files: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.allocator)
	if err != nil {
		fmt.eprintfln("Cannot read directory %s: %v", dir, err)
		return
	}
	defer os.file_info_slice_delete(entries, context.allocator)

	for entry in entries {
		if entry.type == .Directory {
			collect_stx_files(entry.fullpath, files)
		} else if entry.type == .Regular && is_stx_file(entry.name) {
			// Copy the path so it survives deletion of the directory entries.
			path := strings.clone(entry.fullpath)
			append(files, path)
		}
	}
}

// List geometry buffers in an STX file. Returns .None on success; the caller reports problems.
list_buffers :: proc(path: string) -> obj.Error {
	data, ok := obj.read_file(path)
	if !ok {
		return .Read_Failed
	}
	defer delete(data)

	buffers, err := obj.stx_scan(data)
	if err != .None {
		return err
	}
	defer delete(buffers)

	fmt.printfln("%s: %d geometry buffer(s)", path, len(buffers))

	for b, i in buffers {
		fmt.printfln(
			"  [%d] level %v  %d vertices  %d triangles  %d-bit indices",
			i,
			b.level,
			b.vertex_count,
			b.face_count,
			16 if b.narrow else 32,
		)
	}

	return .None
}

// Replace the final extension with .obj.
obj_path_for :: proc(input: string) -> string {
	dot := strings.last_index_byte(input, '.')
	slash := max(strings.last_index_byte(input, '/'), strings.last_index_byte(input, '\\'))

	stem := input[:dot] if dot > slash else input
	return fmt.aprintf("%s.obj", stem)
}

usage :: proc() {
	fmt.eprintln("usage: objconv [options] <input.stx | directory> [...]")
	fmt.eprintln("")
	fmt.eprintln("  Directories are searched recursively for .stx files")
	fmt.eprintln("  -o, --out <file>   output path (single input only)")
	fmt.eprintln("  --no-weld          keep vertices exactly as stored")
	fmt.eprintln("  --flip-z           negate Z (inside-out unless combined with --flip-winding)")
	fmt.eprintln("  --flip-winding     reverse every triangle's orientation")
	fmt.eprintln("  --level <number>   STX geometry buffer to take (default 1)")
	fmt.eprintln("  --list             print geometry buffers instead of converting")
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("objconv: ")
	fmt.eprintfln(format, ..args)
	os.exit(2)
}
