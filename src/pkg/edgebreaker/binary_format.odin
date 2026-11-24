package edgebreaker

import "base:intrinsics"

/*
Binary file layout.

Fixed-width values are little endian. "uvarint" is an unsigned LEB128 integer,
"ivarint" is a zigzag-encoded signed LEB128 integer.

	magic            4 bytes   "EDGB"
	version          u16       BINARY_VERSION
	vertex codec     u8        Vertex_Codec_Kind
	coord size       u8        4 (f32) or 8 (f64)

	symbol count     uvarint
	symbols          bitstream, MSB first, padded with 0 bits to a full byte
	                 (CLERS prefix code, see symbol_code)

	topology count   uvarint
	  per entry:     s_step ivarint, arrival_step ivarint,
	                 arrival_side u8, hole_len ivarint

	component count  uvarint
	  per entry:     outer_boundary ivarint

	vertex count     uvarint
	  per vertex:    x, y, z as raw floats

The reader rejects anything whose magic or version differs from the constants
below. Bump BINARY_VERSION whenever the layout changes, that includes any change
to the fields of Encoded_Mesh, Topology_Entry, Component_Info or the enums.
*/

@(private)
BINARY_MAGIC :: [4]byte{'E', 'D', 'G', 'B'}

@(private)
BINARY_VERSION :: u16(1)

// Scalar type of one vertex coordinate (f32 or f64, whatever Vector3 uses).
@(private)
Coord_Scalar :: type_of(Vector3{}.x)

#assert(intrinsics.type_is_float(Coord_Scalar))
#assert(size_of(Coord_Scalar) == 4 || size_of(Coord_Scalar) == 8)

/*
CLERS prefix code (Rossignac): C = 0, S = 100, R = 101, L = 110, E = 111.
C is the most frequent symbol, so this costs about 2 bits per triangle or less.

Returns nbits == 0 for a value that cannot be encoded.
*/
@(private)
symbol_code :: proc(op: Operation) -> (code: u8, nbits: uint) {
	switch op {
	case .C:
		return 0b0, 1
	case .S:
		return 0b100, 3
	case .R:
		return 0b101, 3
	case .L:
		return 0b110, 3
	case .E:
		return 0b111, 3
	}
	return 0, 0
}

/*
Inverse of symbol_code for everything except C: takes the two bits that follow
the leading 1 bit.
*/
@(private)
symbol_from_suffix :: proc(suffix: u8) -> Operation {
	switch suffix & 0b11 {
	case 0b00:
		return .S
	case 0b01:
		return .R
	case 0b10:
		return .L
	}
	return .E
}

// Written as a full switch on purpose: a new codec is a compile error here
// until it is accepted explicitly.
@(private)
valid_codec :: proc(k: Vertex_Codec_Kind) -> bool {
	switch k {
	case .RAW, .DELTA_PARALLELOGRAM:
		return true
	}
	return false
}
