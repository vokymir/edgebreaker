package corner_table

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// return TRUE on success, FALSE on error
load_obj :: proc(filepath: string, ct: ^Corner_Table) -> (ok := false) {
	data, err := os.read_entire_file(filepath, context.allocator)
	if err != nil {
		return
	}
	defer delete(data, context.allocator)

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		process_line(line, ct)
	}

	ok = true
	return
}

process_line :: proc(line: string, ct: ^Corner_Table) {
	if len(line) < 2 {
		return
	}
	switch line[0:2] {
	case "v ":
		process_vertex(line, ct)
	case "f ":
		process_face(line, ct)
	}
}

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

parse_face_vertex :: proc(str: string) -> (v: Vertex, ok := false) {
	tokens := strings.split(str, "/")
	v_int := strconv.parse_int(tokens[0]) or_return

	v = Vertex(v_int)
	ok = true
	return
}

main :: proc() {
	ct := new(Corner_Table)
	{
		init(ct)
		defer destroy(ct)
		load_obj("lowpoly_tree.obj", ct)

		fmt.print(len(ct.g), "\n")
		fmt.print(len(ct.v), "\n")
	}

	{
		init(ct)
		defer destroy(ct)
		load_obj("polyhedron.obj", ct)

		fmt.print(len(ct.g), "\n")
		fmt.print(len(ct.v), "\n")
	}
}
