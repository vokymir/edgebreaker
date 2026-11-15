#+private file
package edgebreaker

import "base:intrinsics"
import "core:log"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

@(private)
read_file_binary :: proc(filename: string) -> ^Encoded_Mesh {
	// TODO: impl
	return nil
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
