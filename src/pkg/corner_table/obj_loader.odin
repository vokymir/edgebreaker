package corner_table

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

/* 
Load graph stored on disk in <filepath> into memory represented via Corner_Table. 

Supported formats to load from:
- [OBJ](https://en.wikipedia.org/wiki/Wavefront_.obj_file): only simple ones

Inputs:
- filepath: the path to file on disk
- ct: ptr to initialized Corner_Table
- allocator: allocator used for temporary structures (unused after return)
- loc: caller location

Returns:
- ok: true on success, false (without no further indication about what went
wrong) on error
*/
load :: proc {
	load_obj_to_ct,
}

@(private)
load_obj_to_ct :: proc(
	filepath: string,
	ct: ^Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	ok := false,
) {
	data, err := os.read_entire_file(filepath, allocator, loc)
	if err != nil {
		return
	}
	defer delete(data, allocator)

	// part 1: store geometry
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		// ok to handwave, doesn't handle all line-types in .obj file, therefore
		// many lines are 'invalid'
		_ = process_line(line, ct)
	}

	// part 2:
	build_topology(ct, allocator, loc)

	return
}

/*
Determine what type of line it is and call corresponding procedure.

Inputs:
- line: line from .obj file
- ct: ptr to Corner Table

Returns:
- ok: false if anything bad happens
*/
@(private = "file")
process_line :: proc(line: string, ct: ^Corner_Table) -> (ok := false) {
	if len(line) < 2 {
		return
	}
	switch line[0:2] {
	case "v ":
		ok = process_vertex(line, ct)
	case "f ":
		ok = process_face(line, ct)
	}

	return
}

/*
Process vertex line from the .obj file and store it in the Corner Table.

Inputs:
- line: line from .obj file
- ct: ptr to Corner Table

Returns:
- ok: false if invalid line or parsing fail
*/
@(private = "file")
process_vertex :: proc(line: string, ct: ^Corner_Table) -> (ok := false) {
	tokens := strings.split(line, " ")
	if len(tokens) < 4 || len(tokens) > 5 {
		return
	}

	w: f32 = 1
	if len(tokens) == 5 {
		w = strconv.parse_f32(tokens[4]) or_return
	}

	x := strconv.parse_f32(tokens[1]) or_return
	y := strconv.parse_f32(tokens[2]) or_return
	z := strconv.parse_f32(tokens[3]) or_return

	append(&ct.g, Vec3{x / w, y / w, z / w})

	ok = true
	return
}

/*
Process face line from the .obj file and store it in the Corner Table.

Inputs:
- line: line from .obj file
- ct: ptr to Corner Table

Returns:
- ok: false if invalid line or parsing fail
*/
@(private = "file")
process_face :: proc(line: string, ct: ^Corner_Table) -> (ok := false) {
	tokens := strings.split(line, " ")
	if len(tokens) < 4 {
		return
	}

	v1 := parse_face_vertex(tokens[1]) or_return

	// support any polygon by splitting it inside multiple triangles coincident
	// with the vertex v1
	for i := 3; i < len(tokens); i += 1 {
		v2 := parse_face_vertex(tokens[i - 1]) or_return
		v3 := parse_face_vertex(tokens[i]) or_return

		append(&ct.v, v1, v2, v3)
	}

	ok = true
	return
}

/*
In .obj the vertex of a face might be represented as 2 or 2/3 or 2/3/4 where
only 2 is the vertex idx and the other values are texture/normals related.

Inputs:
- str: string in format "X(/X)*" where X is 0..<inf

Returns:
- v: vertex idx
- ok: false if invalid str or parsing fail
*/
@(private = "file")
parse_face_vertex :: proc(str: string) -> (v: Vertex, ok := false) {
	tokens := strings.split(str, "/")
	v_int := strconv.parse_int(tokens[0]) or_return

	// the -1 is important, in .obj the vertices are 1-indexed
	v = Vertex(v_int - 1)

	ok = true
	return
}

/*
Build the topology of given Corner Table based on its geometry and vertices.
Assumes the Corner Table to be initialized and its g,v filled.
After return, the Corner Table is modified to contain the opposites and v2c
arrays.

Inputs:
- ct: ptr to Corner Table
- allocator: allocator used for edge map
- loc: caller location
*/
@(private = "file")
build_topology :: proc(
	ct: ^Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	num_corners := len(ct.v)
	num_vertices := len(ct.g)

	resize(&ct.o, num_corners, loc)
	slice.fill(ct.o[:], INVALID_CORNER)

	resize(&ct.v2c, num_vertices, loc)

	Edge :: struct {
		v1, v2: Vertex,
	}
	edge_map := make(map[Edge]Corner, allocator, loc)
	defer delete(edge_map)

	for c in 0 ..< Corner(num_corners) {
		v := ct.v[c]
		v1 := ct.v[corner_next(c)]
		v2 := ct.v[corner_prev(c)]

		// simply write-over anything, doesn't matter
		ct.v2c[v] = c

		directed_edge := Edge{v1, v2}
		opposite_edge := Edge{v2, v1}

		if opp_corner, exists := edge_map[opposite_edge]; exists {
			ct.o[c] = opp_corner
			ct.o[opp_corner] = c
			// be easy on memory
			delete_key(&edge_map, opposite_edge)
		} else {
			edge_map[directed_edge] = c
		}
	}

	return
}
