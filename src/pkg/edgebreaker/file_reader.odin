#+private file
package edgebreaker

import "base:intrinsics"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

/*
Reads the binary format described in binary_format.odin.

Returns nil if the file cannot be read, is not an edgebreaker binary file, has a
different format version than this build (BINARY_VERSION), or is truncated or
corrupt. The version is checked right after the magic, before anything else in
the file is interpreted.
*/
@(private)
read_file_binary :: proc(
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> ^Encoded_Mesh {
	data, ferr := os.read_entire_file(filename, allocator, loc)
	if ferr != os.ERROR_NONE {
		log.debug("Cannot read input file:", ferr)
		return nil
	}
	defer delete(data, allocator)

	r := Byte_Reader {
		data    = data,
		section = "header",
	}

	// magic
	expected := BINARY_MAGIC
	for want in expected {
		got, gok := get_le(&r, u8)
		if !gok || got != want {
			log.debug("Not an edgebreaker binary file (bad magic)")
			return nil
		}
	}

	// version: if it differs, we do not touch the rest of the file
	version, vok := get_le(&r, u16)
	if !vok {
		log.debug("Binary file is truncated (no version)")
		return nil
	}
	if version != BINARY_VERSION {
		log.debugf(
			"Unsupported binary format version %d, this build reads version %d",
			version,
			BINARY_VERSION,
		)
		return nil
	}

	codec_byte, cok := get_le(&r, u8)
	coord_size, sok := get_le(&r, u8)
	if !cok || !sok {
		log.debug("Binary file is truncated (header)")
		return nil
	}
	codec := Vertex_Codec_Kind(codec_byte)
	if !valid_codec(codec) {
		log.debugf("Invalid vertex codec %d", codec_byte)
		return nil
	}
	if int(coord_size) != size_of(Coord_Scalar) {
		log.debugf(
			"Coordinate size mismatch: file has %d bytes, this build uses %d",
			coord_size,
			size_of(Coord_Scalar),
		)
		return nil
	}

	em := new(Encoded_Mesh, allocator, loc)
	ok := false
	defer if !ok {
		destroy_em(em)
		free(em, allocator)
	}

	em.vertex_codec = codec
	em.symbols = make(type_of(em.symbols), allocator)
	em.topology = make(type_of(em.topology), allocator)
	em.components = make(type_of(em.components), allocator)
	em.vertices = make(type_of(em.vertices), allocator)

	if !decode_binary_body(&r, em) {
		log.debugf("Malformed binary file (section '%s', byte offset %d)", r.section, r.pos)
		return nil
	}

	ok = true
	return em
}

@(private)
read_file_simple :: proc(
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> ^Encoded_Mesh {
	data, ferr := os.read_entire_file(filename, allocator, loc)
	if ferr != os.ERROR_NONE {
		log.debug("Cannot read input file:", ferr)
		return nil
	}
	defer delete(data, allocator)

	lines := strings.split_lines(string(data), allocator)
	defer delete(lines, allocator)

	em := new(Encoded_Mesh, allocator, loc)
	ok := false
	defer if !ok {
		destroy_em(em)
		free(em, allocator)
	}

	Symbol :: Operation

	em.symbols = make(type_of(em.symbols), allocator)
	em.topology = make(type_of(em.topology), allocator)
	em.components = make(type_of(em.components), allocator)
	em.vertices = make(type_of(em.vertices), allocator)

	Section :: enum {
		None,
		Vertex_Codec,
		Symbols,
		Topology,
		Components,
		Vertices,
	}
	section := Section.None

	for raw, i in lines {
		line := strings.trim_space(raw) // also strips a trailing \r

		switch line {
		case "vertex codec:":
			section = .Vertex_Codec
			continue
		case "symbols:":
			section = .Symbols
			continue
		case "topology:":
			section = .Topology
			continue
		case "components:":
			section = .Components
			continue
		case "vertices:":
			section = .Vertices
			continue
		}

		switch section {
		case .None:
			if line != "" {
				log.debugf("line %d: unexpected content before first section", i + 1)
				return nil
			}

		case .Vertex_Codec:
			if line == "" {continue}
			codec, cok := parse_as(line, type_of(em.vertex_codec))
			if !cok {
				log.debugf("line %d: invalid vertex codec '%s'", i + 1, line)
				return nil
			}
			em.vertex_codec = codec

		case .Symbols:
			// one line, one character per symbol (may be empty)
			for j in 0 ..< len(line) {
				sym, sok := parse_as(line[j:j + 1], Symbol)
				if !sok {
					log.debugf("line %d: invalid symbol '%s'", i + 1, line[j:j + 1])
					return nil
				}
				append(&em.symbols, sym)
			}

		case .Topology:
			if line == "" {continue}
			rest := line
			top: type_of(em.topology[0])
			a, b, c, d: bool
			top.s_step, a = next_as(&rest, type_of(top.s_step))
			top.arrival_step, b = next_as(&rest, type_of(top.arrival_step))
			top.arrival_side, c = next_as(&rest, type_of(top.arrival_side))
			top.hole_len, d = next_as(&rest, type_of(top.hole_len))
			if !(a && b && c && d) {
				log.debugf("line %d: invalid topology entry '%s'", i + 1, line)
				return nil
			}
			append(&em.topology, top)

		case .Components:
			if line == "" {continue}
			rest := line
			comp: type_of(em.components[0])
			cok: bool
			comp.outer_boundary, cok = next_as(&rest, type_of(comp.outer_boundary))
			if !cok {
				log.debugf("line %d: invalid component '%s'", i + 1, line)
				return nil
			}
			append(&em.components, comp)

		case .Vertices:
			if line == "" {continue}
			rest := line
			v: type_of(em.vertices[0])
			x, y, z: bool
			v.x, x = next_as(&rest, type_of(v.x))
			v.y, y = next_as(&rest, type_of(v.y))
			v.z, z = next_as(&rest, type_of(v.z))
			if !(x && y && z) {
				log.debugf("line %d: invalid vertex '%s'", i + 1, line)
				return nil
			}
			append(&em.vertices, v)
		}
	}

	ok = true
	return em
}

/***************************** Binary body decoding ****************************/

// Everything after the header. Plain truncation just returns false (the caller
// logs the section and offset), semantic problems are logged here.
decode_binary_body :: proc(r: ^Byte_Reader, em: ^Encoded_Mesh) -> (ok: bool) {
	// symbols
	r.section = "symbols"
	n_symbols := get_count(r, 1) or_return
	reserve(&em.symbols, n_symbols)
	br := Bit_Reader {
		r = r,
	}
	for _ in 0 ..< n_symbols {
		append(&em.symbols, get_symbol(&br) or_return)
	}

	// topology
	r.section = "topology"
	n_topology := get_count(r, 32) or_return
	reserve(&em.topology, n_topology)
	for _ in 0 ..< n_topology {
		top: Topology_Entry
		top.s_step = get_ivarint(r) or_return
		top.arrival_step = get_ivarint(r) or_return
		side := Side(get_le(r, u8) or_return)
		if side != .RIGHT && side != .LEFT {
			log.debugf("Invalid arrival side %d", u8(side))
			return false
		}
		top.arrival_side = side
		top.hole_len = get_ivarint(r) or_return
		append(&em.topology, top)
	}

	// components
	r.section = "components"
	n_components := get_count(r, 8) or_return
	reserve(&em.components, n_components)
	for _ in 0 ..< n_components {
		comp: Component_Info
		comp.outer_boundary = get_ivarint(r) or_return
		append(&em.components, comp)
	}

	// vertices
	r.section = "vertices"
	n_vertices := get_count(r, 3 * 8 * size_of(Coord_Scalar)) or_return
	reserve(&em.vertices, n_vertices)
	for _ in 0 ..< n_vertices {
		v: Vector3
		v.x = get_coord(r) or_return
		v.y = get_coord(r) or_return
		v.z = get_coord(r) or_return
		append(&em.vertices, v)
	}

	if r.pos != len(r.data) {
		log.debugf("%d unexpected trailing bytes", len(r.data) - r.pos)
		return false
	}
	return true
}

/********************************** Helpers ***********************************/

/*
Parse one token (s) into the type (T).
*/
parse_as :: proc(s: string, $T: typeid) -> (val: T, ok: bool) {
	when intrinsics.type_is_enum(T) {
		return reflect.enum_from_name(T, s)
	} else when intrinsics.type_is_boolean(T) {
		b: bool
		b, ok = strconv.parse_bool(s)
		return T(b), ok
	} else when intrinsics.type_is_float(T) {
		f: f64
		f, ok = strconv.parse_f64(s)
		return T(f), ok
	} else when intrinsics.type_is_integer(T) {
		i: i64
		i, ok = strconv.parse_i64(s)
		return T(i), ok
	} else {
		#panic("parse_as: unsupported type")
	}
}

/* 
Takes the next whitespace-separated token from s and parses it as T.
*/
next_as :: proc(s: ^string, $T: typeid) -> (val: T, ok: bool) {
	tok, has := strings.fields_iterator(s)
	if !has {
		return {}, false
	}
	return parse_as(tok, T)
}

// Bounds-checked cursor over the file contents.
Byte_Reader :: struct {
	data:    []byte,
	pos:     int,
	section: string, // only used for error messages
}

// Fixed-width little endian read. T must be an unsigned integer type.
get_le :: proc(r: ^Byte_Reader, $T: typeid) -> (v: T, ok: bool) {
	if r.pos + size_of(T) > len(r.data) {
		return {}, false
	}
	for i in 0 ..< size_of(T) {
		v |= T(r.data[r.pos + i]) << (uint(i) * 8)
	}
	r.pos += size_of(T)
	return v, true
}

get_coord :: proc(r: ^Byte_Reader) -> (c: Coord_Scalar, ok: bool) {
	when size_of(Coord_Scalar) == 4 {
		bits := get_le(r, u32) or_return
		return transmute(Coord_Scalar)bits, true
	} else {
		bits := get_le(r, u64) or_return
		return transmute(Coord_Scalar)bits, true
	}
}

// Unsigned LEB128.
get_uvarint :: proc(r: ^Byte_Reader) -> (v: u64, ok: bool) {
	shift: uint
	for {
		b := get_le(r, u8) or_return
		if shift == 63 && (b & 0x7f) > 1 {
			return 0, false // does not fit into 64 bits
		}
		v |= u64(b & 0x7f) << shift
		if b < 0x80 {
			return v, true
		}
		shift += 7
		if shift > 63 {
			return 0, false
		}
	}
}

// Inverse of put_ivarint (zigzag + LEB128).
get_ivarint :: proc(r: ^Byte_Reader) -> (v: int, ok: bool) {
	u := get_uvarint(r) or_return
	x := i64(u >> 1) ~ -i64(u & 1)
	if i64(int(x)) != x {
		return 0, false
	}
	return int(x), true
}

/*
Reads an element count and rejects counts that cannot possibly fit into the rest
of the file (each element needs at least min_bits_each bits). This stops a
corrupt file from making us allocate gigabytes.
*/
get_count :: proc(r: ^Byte_Reader, min_bits_each: u64) -> (n: int, ok: bool) {
	c := get_uvarint(r) or_return
	if c > u64(len(r.data) - r.pos) * 8 / min_bits_each {
		return 0, false
	}
	return int(c), true
}

// MSB-first bit reading on top of a Byte_Reader.
Bit_Reader :: struct {
	r:    ^Byte_Reader,
	acc:  u8,
	left: uint, // unread bits in acc
}

get_bit :: proc(br: ^Bit_Reader) -> (bit: u8, ok: bool) {
	if br.left == 0 {
		br.acc = get_le(br.r, u8) or_return
		br.left = 8
	}
	br.left -= 1
	return (br.acc >> br.left) & 1, true
}

// Decodes one CLERS symbol, see symbol_code.
get_symbol :: proc(br: ^Bit_Reader) -> (op: Operation, ok: bool) {
	first := get_bit(br) or_return
	if first == 0 {
		return .C, true
	}
	hi := get_bit(br) or_return
	lo := get_bit(br) or_return
	return symbol_from_suffix((hi << 1) | lo), true
}
