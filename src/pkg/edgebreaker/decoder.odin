package edgebreaker

import ct "../corner_table"

Decoder_Type :: enum {
	Wrap_And_Zip,
	Spirale_Reversi,
}

decode :: proc(
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	type := Decoder_Type.Wrap_And_Zip,
	allocator := context.allocator,
	loc := #caller_location,
) {
	switch type {
	case .Wrap_And_Zip:
		decode_wrap_and_zip_ct(em, t, allocator, loc)
	case .Spirale_Reversi:
		panic("not implemented yet")
	}
}
