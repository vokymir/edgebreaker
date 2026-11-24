#+private file
package edgebreaker

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"

/*
Writes the mesh in the binary format described in binary_format.odin.

The whole file is built in memory first, so a mesh that cannot be encoded never
leaves a half-written file behind.
*/
@(private)
write_file_binary :: proc(
	em: Encoded_Mesh,
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	size_hint :=
		32 +
		len(em.symbols) / 2 +
		len(em.topology) * 8 +
		len(em.components) * 2 +
		len(em.vertices) * 3 * size_of(Coord_Scalar)
	buf := make([dynamic]byte, 0, size_hint, allocator, loc)
	defer delete(buf)

	// header
	magic := BINARY_MAGIC
	append(&buf, ..magic[:])
	put_le(&buf, BINARY_VERSION)
	append(&buf, u8(em.vertex_codec))
	append(&buf, u8(size_of(Coord_Scalar)))

	// symbols
	put_uvarint(&buf, u64(len(em.symbols)))
	bw := Bit_Writer {
		buf = &buf,
	}
	for sym in em.symbols {
		code, nbits := symbol_code(sym)
		if nbits == 0 {
			log.debugf("Cannot encode symbol %v", sym)
			return false
		}
		put_bits(&bw, code, nbits)
	}
	flush_bits(&bw)

	// topology
	put_uvarint(&buf, u64(len(em.topology)))
	for top in em.topology {
		put_ivarint(&buf, top.s_step)
		put_ivarint(&buf, top.arrival_step)
		append(&buf, u8(top.arrival_side))
		put_ivarint(&buf, top.hole_len)
	}

	// components
	put_uvarint(&buf, u64(len(em.components)))
	for comp in em.components {
		put_ivarint(&buf, comp.outer_boundary)
	}

	// vertices
	put_uvarint(&buf, u64(len(em.vertices)))
	for v in em.vertices {
		put_coord(&buf, v.x)
		put_coord(&buf, v.y)
		put_coord(&buf, v.z)
	}

	f, err := os.create(filename)
	if err != os.ERROR_NONE {
		log.debug("Cannot create output file:", err)
		return false
	}
	defer os.close(f)

	n, werr := os.write(f, buf[:])
	if werr != os.ERROR_NONE {
		log.debug("Couldn't write into file:", werr)
		return false
	}
	if n != len(buf) {
		log.debugf("Short write: %d of %d bytes", n, len(buf))
		return false
	}

	return true
}

@(private)
write_file_simple :: proc(
	em: Encoded_Mesh,
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> bool {
	f, err := os.create(filename)
	if err != os.ERROR_NONE {
		log.debug("Cannot create output file:", err)
		return false
	}
	defer os.close(f)

	sb := strings.builder_make(allocator, loc)
	defer strings.builder_destroy(&sb)

	fmt.sbprintln(&sb, "vertex codec:")
	fmt.sbprintln(&sb, em.vertex_codec)

	fmt.sbprintln(&sb, "symbols:")
	for sym in em.symbols {
		fmt.sbprint(&sb, sym)
	}
	fmt.sbprintln(&sb)

	fmt.sbprintln(&sb, "topology:")
	for top in em.topology {
		fmt.sbprintln(&sb, top.s_step, top.arrival_step, top.arrival_side, top.hole_len)
	}

	fmt.sbprintln(&sb, "components:")
	for comp in em.components {
		fmt.sbprintln(&sb, comp.outer_boundary)
	}

	fmt.sbprintln(&sb, "vertices:")
	for v in em.vertices {
		fmt.sbprintln(&sb, v.x, v.y, v.z)
	}

	_, err = os.write_string(f, strings.to_string(sb))
	if err != os.ERROR_NONE {
		log.debug("Couldn't write string into file:", err)
		return false
	}

	return true
}

/********************************** Helpers ***********************************/

// Fixed-width little endian write. T must be an unsigned integer type.
put_le :: proc(b: ^[dynamic]byte, v: $T) {
	x := v
	for _ in 0 ..< size_of(T) {
		append(b, byte(x))
		x >>= 8
	}
}

put_coord :: proc(b: ^[dynamic]byte, c: Coord_Scalar) {
	when size_of(Coord_Scalar) == 4 {
		put_le(b, transmute(u32)c)
	} else {
		put_le(b, transmute(u64)c)
	}
}

// Unsigned LEB128.
put_uvarint :: proc(b: ^[dynamic]byte, v: u64) {
	x := v
	for x >= 0x80 {
		append(b, byte(x) | 0x80)
		x >>= 7
	}
	append(b, byte(x))
}

// Zigzag + LEB128, so small negative numbers stay small too.
put_ivarint :: proc(b: ^[dynamic]byte, v: int) {
	x := i64(v)
	put_uvarint(b, u64((x << 1) ~ (x >> 63)))
}

// MSB-first bit packing on top of a byte buffer.
Bit_Writer :: struct {
	buf: ^[dynamic]byte,
	acc: u8,
	n:   uint, // number of bits currently in acc
}

// Writes the lowest nbits bits of code, most significant of them first.
put_bits :: proc(bw: ^Bit_Writer, code: u8, nbits: uint) {
	for i := nbits; i > 0; i -= 1 {
		bw.acc = (bw.acc << 1) | ((code >> (i - 1)) & 1)
		bw.n += 1
		if bw.n == 8 {
			append(bw.buf, bw.acc)
			bw.acc, bw.n = 0, 0
		}
	}
}

// Pads the last partial byte with zero bits.
flush_bits :: proc(bw: ^Bit_Writer) {
	if bw.n > 0 {
		append(bw.buf, bw.acc << (8 - bw.n))
		bw.acc, bw.n = 0, 0
	}
}
