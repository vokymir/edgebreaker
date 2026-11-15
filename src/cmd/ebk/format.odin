package cmd

import "core:fmt"
import "core:path/filepath"
import "core:strings"

/**************************** SUPPORTED FORMATS *******************************/

Format :: enum {
	OBJ,
	SIMPLE_EBK,
	EBK,
}

Format_Info :: struct {
	extension:        string,
	description:      string,
	operation_encode: bool,
	default_pair:     Format,
}

FORMAT_INFO := [3]Format_Info {
	{".obj", "Uncompressed mesh", true, .SIMPLE_EBK},
	{".simple.ebk", "Human-readable compressed mesh", false, .OBJ},
	{".ebk", "Compressed mesh", false, .OBJ},
}

format_info :: proc(format: Format) -> Format_Info {
	return FORMAT_INFO[int(format)]
}

format_extension :: proc(format: Format) -> string {
	return format_info(format).extension
}

format_from_filename :: proc(filename: string) -> (Format, bool) {
	file_extension := filepath.long_ext(filename)

	for format in Format {
		info := format_info(format)
		if file_extension == info.extension {return format, true}
	}

	return .OBJ, false
}
