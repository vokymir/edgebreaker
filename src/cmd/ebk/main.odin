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
		outf = strings.concatenate({filepath.stem(opt.input), ".simple.ebk"}, context.allocator)
	}

	switch filepath.ext(opt.input) {
	case ".obj":
		table: ct.Corner_Table
		ct.init(&table)
		defer ct.destroy(&table)

		if !ct.load(&table, opt.input) {
			log.fatal("cannot load", opt.input)
			os.exit(1)
		}

		ok, em := eb.compress(table, eb.predictor_of(opt.predictor))
		if !ok {
			log.fatal("compression failed")
			os.exit(1)
		}
		defer free(em) // runs second
		defer eb.destroy_em(em) // runs first

		log.debug("start write")
		if !eb.write(em^, outf) {
			log.fatal("write failed")
		}
	case ".ebk":
	//decode
	}
}
