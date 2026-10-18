package cmd

import ct "../../pkg/corner_table"
import eb "../../pkg/edgebreaker"
import "core:flags"
import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

Handler_Kind :: enum {
	// human-readable
	SYMBOL,
	// binary file
	RAW,
}

Options :: struct {
	input:     string `args:"pos=0,required" usage:"Input .obj to encode or .ebk file
  to decode."`,
	output:    string `args:"name=out" usage:"Optional output file path."`,
	predictor: eb.Predictor_Kind `args:"name=pred" usage:"Optional predictor
  selection."`,
	handler:   Handler_Kind `args:"name=stream" usage:"Select compression format
  (only for compression)."`,
}

main :: proc() {
	context.logger = log.create_console_logger()
	opt: Options
	flags.parse_or_exit(&opt, os.args)

	outf := opt.output
	if len(outf) == 0 {
		outf = strings.concatenate({filepath.stem(opt.input), ".output_kamo"}, context.allocator)
	}
	fmt.println(outf)

	switch filepath.ext(opt.input) {
	case ".obj":
		fmt.println("loading obj")
		table: ct.Corner_Table
		ct.init(&table)
		ct.load(&table, opt.input)
		// ct.save(table, opt.input)

		f, err := os.open(outf, {.Write, .Create, .Trunc})
		if err != nil {
			panic("invalid output path")
		}
		defer os.close(f)
		eb.Save_Text_Handler.user_data = f

		es: eb.Encoder_State
		eb.init_es(&es, len(table.geometry), len(table.vertices), eb.Save_Text_Handler)

		fmt.println("compressing")
		eb.compress(table, &es)
		fmt.println("done")
	// encode
	case ".ebk":
	//decode
	}
}
