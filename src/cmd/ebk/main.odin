package cmd

import ct "../../pkg/corner_table"
import eb "../../pkg/edgebreaker"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

/********************************* RETURN CODES *******************************/

Error :: enum u8 {
	OK                                 = 0,
	DONE                               = 1,
	INVALID_INPUT_FILE                 = 2,
	INVALID_OUTPUT_FILE_COMPLETELY     = 3,
	INVALID_OUTPUT_FILE_FOR_INPUT_FILE = 4,
	CANNOT_LOAD_FILE                   = 5,
	COMPRESSION_FAILED                 = 6,
	FAILED_WRITE                       = 7,
}

/********************************** CLI OPTIONS *******************************/

Options :: struct {
	input:        string `args:"pos=0" usage:"Input file to (de)compress,
  supported formats can be view via -formats."`,
	output:       string `args:"name=out" usage:"Optional output file path."`,
	vertex_codec: eb.Vertex_Codec_Kind `args:"name=codec" usage:"Optional vertex codec selection.
  (only for compression, in .ebk file the codec is already selected.)"`,
	formats:      bool `args:"name=formats" usage:"List supported file formats."`,
}

/******************************** PROCS ***************************************/

main :: proc() {
	context.logger = log.create_console_logger()
	defer log.destroy_console_logger(context.logger)
	opt: Options
	flags.parse_or_exit(&opt, os.args)

	output_allocated := opt.output == "" // validate_options will allocate it
	defer if output_allocated {
		delete(opt.output)
	}

	err := validate_options(&opt)
	if err == .DONE {
		return
	}
	if err != .OK {
		os.exit(int(err))
	}

	f, _ := format_from_filename(opt.input) // opt.input validated before
	switch f {
	case .OBJ:
		handle_encode(opt)
	case .EBK:
		panic("not implemented yet")
	// fallthrough // use here after is implemented
	case .SIMPLE_EBK:
		handle_decode(opt)
	}
}

validate_options :: proc(opt: ^Options) -> Error {
	if opt.formats { 	// user wants to know about formats
		print_formats()
		return .DONE
	}

	if opt.input == "" { 	// no input file given
		flags.write_usage(os.to_stream(os.stdout), typeid_of(Options), os.args[0])
		return .DONE
	}

	input_format, inp_ok := format_from_filename(opt.input)
	if !inp_ok { 	// unsupported input file
		fmt.print("invalid input file format")
		return .INVALID_INPUT_FILE
	}
	inp_info := format_info(input_format)

	if opt.output == "" { 	// set default output path next to the input file
		dir := filepath.dir(opt.input) // may alias opt.input, do not delete

		name := strings.concatenate(
			{filepath.short_stem(opt.input), format_info(inp_info.default_pair).extension},
		)
		defer delete(name)

		p, _ := filepath.join({dir, name}) // allocates its own result
		opt.output = p
	}

	output_format, out_ok := format_from_filename(opt.output)
	if !out_ok {
		fmt.print("invalid output file format", output_format, opt.output)
		return .INVALID_OUTPUT_FILE_COMPLETELY
	}
	out_info := format_info(output_format)

	if inp_info.operation_encode == out_info.operation_encode {
		fmt.print("input file cannot be converted to specified output file")
		return .INVALID_OUTPUT_FILE_FOR_INPUT_FILE
	}

	return .OK
}

handle_encode :: proc(opt: Options) -> Error {
	table: ct.Corner_Table
	ct.init(&table)
	defer ct.destroy(&table)

	if !ct.load(&table, opt.input) {
		log.fatal("cannot load file", opt.input)
		return .CANNOT_LOAD_FILE
	}

	em, ok := eb.compress(table, eb.vertex_codec_of(opt.vertex_codec))
	if !ok {
		log.fatal("compression failed")
		return .COMPRESSION_FAILED
	}
	defer eb.destroy_em(em)

	if !eb.write(em^, opt.output) {
		log.fatal("failed write to file", opt.output)
		return .FAILED_WRITE
	}

	return .OK
}

handle_decode :: proc(opt: Options) -> Error {
	em, ok := eb.read(opt.input)
	if !ok {
		log.fatal("cannot load file", opt.input)
		return .CANNOT_LOAD_FILE
	}

	table: ct.Corner_Table
	ct.init(&table)
	defer ct.destroy(&table)

	eb.decode(em^, &table)

	ok = ct.save(table, opt.output)
	if !ok {
		log.fatal("failed write to file", opt.output)
		return .FAILED_WRITE
	}

	return .OK
}
