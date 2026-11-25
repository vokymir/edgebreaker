package main

// objconv: convert mesh files to Wavefront OBJ using package obj.
//
//   odin build src/objconv -out:objconv
//   objconv scan1.stx scan2.stx ...          writes scan1.obj, scan2.obj next to the inputs
//
// Options:
//   -o, --out <file>     output path (only valid with exactly one input)
//   --no-weld            keep vertices exactly as stored (no merging, unused ones kept)
//   --flip-z             negate Z, as the old C# importer did
//   --flip-winding       reverse the orientation of every triangle
//   --level <number>     STX geometry buffer to take (default 1)
//   --list               only print the geometry buffers found in each STX file

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import obj "../../pkg/obj"

main :: proc() {
	opts: obj.Options
	inputs: [dynamic]string
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
	if out_path != "" && len(inputs) != 1 {
		die("-o/--out works with exactly one input file")
	}

	failures := 0
	for input in inputs {
		if list_only {
			if !list_buffers(input) {
				failures += 1
			}
			continue
		}

		output := out_path if out_path != "" else obj_path_for(input)
		if err := obj.convert_file(input, output, opts); err != .None {
			fmt.eprintfln("%s: %s", input, obj.error_message(err))
			failures += 1
			continue
		}
		fmt.printfln("%s -> %s", input, output)
	}

	if failures > 0 {
		fmt.eprintfln("%d of %d file(s) failed", failures, len(inputs))
		os.exit(1)
	}
}

// list_buffers prints what an STX file contains, to help choose --level.
list_buffers :: proc(path: string) -> bool {
	data, ok := obj.read_file(path)
	if !ok {
		fmt.eprintfln("%s: %s", path, obj.error_message(.Read_Failed))
		return false
	}
	defer delete(data)

	buffers, err := obj.stx_scan(data)
	if err != .None {
		fmt.eprintfln("%s: %s", path, obj.error_message(err))
		return false
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
	return true
}

// obj_path_for swaps the extension of `input` for ".obj" (or appends it if there is none).
obj_path_for :: proc(input: string) -> string {
	dot := strings.last_index_byte(input, '.')
	slash := max(strings.last_index_byte(input, '/'), strings.last_index_byte(input, '\\'))
	stem := input[:dot] if dot > slash else input
	return fmt.aprintf("%s.obj", stem)
}

usage :: proc() {
	fmt.eprintln("usage: objconv [options] <input.stx> [<input.stx> ...]")
	fmt.eprintln(
		"  -o, --out <file>   output path (single input only); default: input with .obj extension",
	)
	fmt.eprintln("  --no-weld          keep vertices exactly as stored")
	fmt.eprintln("  --flip-z           negate Z (the old C# importer did this)")
	fmt.eprintln("  --flip-winding     reverse every triangle's orientation")
	fmt.eprintln("  --level <number>   STX geometry buffer to take (default 1)")
	fmt.eprintln("  --list             print the geometry buffers in each STX file and exit")
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintf("objconv: ")
	fmt.eprintfln(format, ..args)
	os.exit(2)
}
