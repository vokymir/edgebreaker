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

print_formats :: proc() {
	fmt.println("Supported formats:")
	fmt.println("")

	fmt.printf("  %-14s %-38s %-10s %s\n", "EXTENSION", "DESCRIPTION", "OPERATION", "DEFAULT PAIR")

	fmt.printf("  %s\n", strings.repeat("-", 78))

	for format in Format {
		info := format_info(format)

		operation := "Decode"
		if info.operation_encode {
			operation = "Encode"
		}

		pair := format_extension(info.default_pair)

		fmt.printf("  %-14s %-38s %-10s %s\n", info.extension, info.description, operation, pair)
	}
}
