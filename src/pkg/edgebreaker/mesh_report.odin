package edgebreaker

import ct "../corner_table"
import "core:fmt"

/*
Report about the mesh.
*/
Mesh_Report :: struct {
	// should be len() == 0 for orientable surfaces
	same_dir_edges:        [dynamic]Mesh_Report_Edge,
	// unoriented edges which are used more than two times, should be 0 for manifolds
	nonmanifold_edges:     [dynamic]Mesh_Report_Edge,
	//
	nonmanifold_vertices:  [dynamic]Mesh_Report_Vertex,
	// # border edges
	border:                int,
	// # unreferenced vertices
	unreferenced_vertices: [dynamic]Mesh_Report_Vertex,
}
Mesh_Report_Edge :: struct {
	a, b: ct.Vertex,
}
Mesh_Report_Vertex :: struct {
	v:          ct.Vertex,
	neighs:     int, // # neighbours
	boundaries: int, // # boundary edges originating in here
}

destroy_report :: proc(r: ^Mesh_Report, loc := #caller_location) {
	delete(r.same_dir_edges, loc)
	delete(r.nonmanifold_edges, loc)
	delete(r.nonmanifold_vertices, loc)
	delete(r.unreferenced_vertices, loc)
}

print_mesh_report :: proc(r: Mesh_Report) {
	fmt.printfln("---- mesh report ----")
	fmt.printfln("border edges: %v", r.border)

	fmt.printfln("non-manifold edges (%v):", len(r.nonmanifold_edges))
	for e in r.nonmanifold_edges {fmt.printfln("  %v -- %v", e.a, e.b)}

	fmt.printfln("non-manifold vertices (%v):", len(r.nonmanifold_vertices))
	for v in r.nonmanifold_vertices {
		fmt.printfln(
			"  v=%v  incident triangles=%v  border edges from v=%v",
			v.v,
			v.neighs,
			v.boundaries,
		)
	}

	fmt.printfln("edges used in the same direction (%v):", len(r.same_dir_edges))
	for e in r.same_dir_edges {fmt.printfln("  %v -> %v", e.a, e.b)}

	fmt.printfln("unreferenced vertices (%v):", len(r.unreferenced_vertices))
	for v in r.unreferenced_vertices {fmt.printfln("  %v", v.v)}
	fmt.printfln("---------------------")
}

/*
Report about the mesh "niceness". One algorithm might not be comfortable with
some mesh characteristics and this proc helps find that.

Won't cause program crash intentionally.
*/
diagnose_mesh :: proc(
	t: ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) -> (
	r: Mesh_Report,
) {
	edges_count := make(map[Mesh_Report_Edge]int, allocator, loc)
	defer delete(edges_count, loc)
	// count corners incident to given triangle
	incident_count := make([]int, len(t.pos), allocator, loc)
	defer delete(incident_count, allocator, loc)

	r = {
		same_dir_edges        = make([dynamic]Mesh_Report_Edge, allocator, loc),
		nonmanifold_edges     = make([dynamic]Mesh_Report_Edge, allocator, loc),
		nonmanifold_vertices  = make([dynamic]Mesh_Report_Vertex, allocator, loc),
		unreferenced_vertices = make([dynamic]Mesh_Report_Vertex, allocator, loc),
	}

	// go through all triangles (1 triangle is done after three iterations of i)
	for i in 0 ..< len(t.c2v) {
		c := ct.Corner(i)
		v := t.c2v[c]
		assert(v >= 0 && int(v) < len(t.pos), "invalid vertex index", loc)

		edge := Mesh_Report_Edge{t.c2v[ct.next(c)], t.c2v[ct.prev(c)]}
		edges_count[edge] += 1
		// oriented edge used multiple times
		if edges_count[edge] > 1 {append(&r.same_dir_edges, edge)}

		incident_count[v] += 1
	}

	// go through all counted edges
	for e, n in edges_count {
		reverse := edges_count[Mesh_Report_Edge{e.b, e.a}] // 0 if absent
		// unoriented edge used multiple times
		if n + reverse > 2 {append(&r.nonmanifold_edges, e)}
		// +n or +1 is pretty irrelevant for now
		if reverse == 0 {r.border += n}
	}

	fan := make([dynamic]ct.Corner, 0, 8, allocator, loc)
	defer delete(fan, loc)

	for i in 0 ..< len(t.pos) {
		expected := incident_count[i]
		v := ct.Vertex(i)
		mrv := Mesh_Report_Vertex{v, -1, -1}

		// # neighbours
		clear(&fan)
		ct.VC(t, v, &fan, loc)
		mrv.neighs = len(fan)

		// # boundary edges originating in v
		boundary_sides := 0
		for c in fan {
			if ct.left(t, c) == ct.INVALID_CORNER {boundary_sides += 1}
			if ct.right(t, c) == ct.INVALID_CORNER {boundary_sides += 1}
		}
		mrv.boundaries = boundary_sides

		if expected == 0 { 	// unreferenced
			append(&r.unreferenced_vertices, mrv)
		}
		// expected is true, less is if vertex has more than one fan
		if (mrv.neighs != expected) {
			append(&r.nonmanifold_vertices, mrv)
		}
		// manifold vtx has 0 or 2 boundary edges if is interior or boundary
		if boundary_sides != 0 && boundary_sides != 2 {
			append(&r.nonmanifold_vertices, mrv)
		}
	}

	return r
}

/*
Diagnose mesh and if its not nice, print info about it and crash the program.
*/
@(disabled = ODIN_DISABLE_ASSERT)
assert_nice_mesh :: proc(
	t: ct.Corner_Table,
	allocator := context.allocator,
	loc := #caller_location,
) {
	r := diagnose_mesh(t, allocator, loc)
	defer destroy_report(&r, loc)

	ok_manifold_edges := len(r.nonmanifold_edges) == 0
	ok_manifold_vertices := len(r.nonmanifold_vertices) == 0
	ok_orientable := len(r.same_dir_edges) == 0
	ok_alone_vertices := len(r.unreferenced_vertices) == 0

	overall_ok := ok_manifold_edges && ok_manifold_vertices && ok_orientable && ok_alone_vertices

	if !overall_ok {print_mesh_report(r)}

	assert(ok_manifold_edges, "Mesh contains non-manifold edges.", loc)

	assert(ok_manifold_vertices, "Mesh contains non-manifold vertices.", loc)

	assert(ok_orientable, "Mesh contains non-orientable faces.", loc)

	assert(ok_alone_vertices, "Mesh contains unreferenced vertices.", loc)
}
