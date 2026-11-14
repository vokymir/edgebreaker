#+private file
package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:slice"

@(private)
decode_spirale_reversi :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	log.panic("not implemented yet")
}
