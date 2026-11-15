#+private
package edgebreaker

import ct "../corner_table"
import "base:runtime"
import "core:fmt"
import "core:slice"

/*
Shared logic between decoders - package private by default.
*/

/******************************** Types ***************************************/

next :: ct.next
prev :: ct.prev
right_edge :: ct.next
left_edge :: ct.prev

// those assume tip given
gate_start :: ct.next
gate_end :: ct.prev

/*********************************** Structs **********************************/

Decoder_Common_State :: struct {
	t:         ^ct.Corner_Table,
	symbols:   []Operation,
	vertices:  []Vector3,
	allocator: runtime.Allocator,
}

Decoder_Geometry_State :: struct {
	gate_stack:  [dynamic]Gate,
	vtx_pos:     int,
	vertex_done: []bool,
	tri_done:    []bool,
	vtx_codec:   Vertex_Codec,
	// for destroy
	allocator:   runtime.Allocator,
}

/***************************** Structs maintenance helpers ********************/

init_dcs :: proc(
	dcs: ^Decoder_Common_State,
	em: Encoded_Mesh,
	t: ^ct.Corner_Table,
	allocator := context.allocator,
) {
	dcs^ = {
		t         = t,
		symbols   = em.symbols[:],
		vertices  = em.vertices[:],
		allocator = allocator,
	}
}

destroy_dcs :: proc(dsc: ^Decoder_Common_State, loc := #caller_location) {
	// Maybe won't be useless in the future. Good habit to have I guess?
}

init_dgs :: proc(
	dgs: ^Decoder_Geometry_State,
	n_verts, n_tris: int,
	codec: Vertex_Codec_Kind,
	allocator := context.allocator,
	loc := #caller_location,
) {

	dgs^ = {
		gate_stack  = make([dynamic]Gate, allocator, loc),
		//
		vtx_pos     = 0,
		vertex_done = make([]bool, n_verts, allocator, loc),
		tri_done    = make([]bool, n_tris, allocator, loc),
		vtx_codec   = vertex_codec_of(codec),
		//
		allocator   = allocator,
	}
}

destroy_dgs :: proc(dgs: ^Decoder_Geometry_State, loc := #caller_location) {
	delete(dgs.gate_stack, loc)
	delete(dgs.vertex_done, dgs.allocator, loc)
	delete(dgs.tri_done, dgs.allocator, loc)
}

/*************************** Geometry Pass In The Whole ***********************/

/*
Decode geometry of all components.

Inputs:
- starts: tip corner of the first triangle of each component
- components: same length as starts
*/
decode_geometry :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	starts: []ct.Corner,
	components: []Component_Info,
) {
	assert(len(starts) == len(components), "one start per component expected")

	for comp, i in components {
		decode_component_geometry(dcs, dgs, starts[i], comp)
	}
	assert(dgs.vtx_pos == len(dcs.vertices), "unused vertices")
}

/*
Decode geometry of one component.
*/
decode_component_geometry :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	start: ct.Corner,
	comp: Component_Info,
) {
	decode_gate_vertices(dcs, dgs, start, comp.outer_boundary > 0)
	decode_geometry_triangles(dcs, dgs, start)
}

/*
Decode first vertices in component, different for boundary&closed component.
*/
decode_gate_vertices :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	tip: ct.Corner,
	has_boundary: bool,
) {
	t := dcs.t
	gs_c := gate_start(tip)
	gs := ct.c2v(t^, gs_c)

	t.pos[gs] = read_vertex(dcs, dgs)
	dgs.vertex_done[gs] = true

	if has_boundary {
		decode_hole_vertices(dcs, dgs, gs_c)
	} else {
		ge := ct.c2v(t^, gate_end(tip))
		t.pos[ge] = dgs.vtx_codec.decode_loop(t.pos[gs], read_vertex(dcs, dgs))
		dgs.vertex_done[ge] = true
	}
}

decode_geometry_triangles :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	start: ct.Corner,
) {
	t := dcs.t^
	assert(len(dgs.gate_stack) == 0, "gate stack must be empty between components")

	gate := start
	for gate != ct.INVALID_CORNER {
		dgs.tri_done[ct.c2t(gate)] = true

		// symbol must be decided before tip is decoded (known vs not)
		symbol := geometry_symbol(t, dgs^, gate)
		decode_tip_vertex(dcs, dgs, gate)

		switch symbol {
		case .C, .L:
			gate = ct.right_of(t, gate)
		case .R:
			gate = ct.left_of(t, gate)
		case .S:
			push_gate(&dgs.gate_stack, ct.left_of(t, gate))
			gate = ct.right_of(t, gate)
		case .E:
			gate = pop_undecoded_gate(dgs)
		}
	}
}

/*
Is exactly the same decision as in encoder decide_clers.
*/
geometry_symbol :: proc(
	t: ct.Corner_Table,
	dgs: Decoder_Geometry_State,
	gate: ct.Corner,
) -> Operation {
	tip_is_new := !dgs.vertex_done[ct.c2v(t, gate)] && !ct.border_c(t, gate)
	right_done := neighbour_done(dgs, ct.right_of(t, gate))
	left_done := neighbour_done(dgs, ct.left_of(t, gate))

	return clers_symbol(tip_is_new, right_done, left_done)
}

// border = also done
neighbour_done :: proc(dgs: Decoder_Geometry_State, c: ct.Corner) -> bool {
	return c == ct.INVALID_CORNER || dgs.tri_done[ct.c2t(c)]
}

/*
Decode the tip vertex position if tip is new.

Encoder brother = smart_vertex_emit
*/
decode_tip_vertex :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	gate: ct.Corner,
) {
	t := dcs.t
	v := ct.c2v(t^, gate)
	if dgs.vertex_done[v] {return}

	if tip_prediction_available(t^, dgs^, gate) {
		ctx := vertex_codec_context(t^, gate)
		t.pos[v] = dgs.vtx_codec.decode_tip(ctx, read_vertex(dcs, dgs))
	} else {
		ge := ct.c2v(t^, gate_end(gate))
		t.pos[v] = dgs.vtx_codec.decode_loop(t.pos[ge], read_vertex(dcs, dgs))
	}
	dgs.vertex_done[v] = true

	if ct.border_c(t^, gate) {
		decode_hole_vertices(dcs, dgs, gate)
	}
}

// the op vtx to gate exists & is decoded
tip_prediction_available :: proc(
	t: ct.Corner_Table,
	dgs: Decoder_Geometry_State,
	gate: ct.Corner,
) -> bool {
	o := ct.op(t, gate)
	return o != ct.INVALID_CORNER && dgs.vertex_done[ct.c2v(t, o)]
}

/*
Decode all vertices of the border loop that corner c is on (c itself is
expected to be decoded already).
*/
decode_hole_vertices :: proc(
	dcs: ^Decoder_Common_State,
	dgs: ^Decoder_Geometry_State,
	c: ct.Corner,
) {
	t := dcs.t
	initial := ct.c2v(t^, c)
	curr := c

	for {
		n, found := ct.next_on_border(t^, curr)
		assert(found, "border walk left the border...")

		v := ct.c2v(t^, n)
		if v == initial {return} 	// the loop has endeth

		prev_pos := t.pos[ct.c2v(t^, curr)]
		t.pos[v] = dgs.vtx_codec.decode_loop(prev_pos, read_vertex(dcs, dgs))
		dgs.vertex_done[v] = true

		curr = n
	}
}

/**************************** Geometry Pass Helpers ***************************/

read_vertex :: proc(dcs: ^Decoder_Common_State, dgs: ^Decoder_Geometry_State) -> Vector3 {
	assert(dgs.vtx_pos < len(dcs.vertices), "ran out of vertices")
	v := dcs.vertices[dgs.vtx_pos]
	dgs.vtx_pos += 1
	return v
}

/*
Pop geometry gate stack until not decoded gate is found.
*/
pop_undecoded_gate :: proc(dgs: ^Decoder_Geometry_State) -> ct.Corner {
	for len(dgs.gate_stack) > 0 {
		candidate := ct.Corner(pop(&dgs.gate_stack))

		if !dgs.tri_done[ct.c2t(candidate)] {return candidate}
	}
	return ct.INVALID_CORNER
}

/*
Pushes gate to any gate stack (connectivity pass has its own, geometry pass
uses dgs.gate_stack).
*/
push_gate :: #force_inline proc(stack: ^[dynamic]Gate, gate: ct.Corner) {
	append(stack, Gate(gate))
}

/**************************** Corner Table Helpers ****************************/

/*
Make some insides of corner table adequately sized.
*/
prepare_corner_table :: proc(
	t: ^ct.Corner_Table,
	n_vertices, n_triangles: int,
	loc := #caller_location,
) {
	assert(len(t.pos) == 0, "not empty corner table")
	assert(len(t.c2v) == 0, "not empty corner table")
	assert(len(t.op) == 0, "not empty corner table")
	assert(len(t.v2c) == 0, "not empty corner table")

	resize(&t.pos, n_vertices, loc)
	resize(&t.c2v, 3 * n_triangles, loc)
	resize(&t.op, 3 * n_triangles, loc)
	slice.fill(t.c2v[:], ct.INVALID_VERTEX)
	slice.fill(t.op[:], ct.INVALID_CORNER)
}

/*
Fill t.v2c from t.c2v and assert nothing is unresolved.

Precondition: every negative t.op is already ct.INVALID_CORNER (the wrap&zip
decoder has to convert its FREE_* markers first).
*/
fill_v2c :: proc(t: ^ct.Corner_Table, loc := #caller_location) {
	resize(&t.v2c, len(t.pos), loc)
	slice.fill(t.v2c[:], ct.INVALID_CORNER)

	for c in 0 ..< len(t.c2v) {
		v := t.c2v[c]
		assert(v != ct.INVALID_VERTEX, "unresolved corner")
		t.v2c[v] = ct.Corner(c)
	}

	for c in t.v2c {
		assert(c != ct.INVALID_CORNER, "unresolved vertex")
	}
}

/*
Extract S (left) corner and arrival corner from topology entry.
*/
corners_from_topology :: proc(top: Topology_Entry) -> (s: ct.Corner, arrival: ct.Corner) {
	s_tip := ct.Corner(3 * top.s_step)
	arrival_tip := ct.Corner(3 * top.arrival_step)

	s = side_corner(s_tip, .LEFT) // always left side
	arrival = side_corner(arrival_tip, top.arrival_side)

	return s, arrival
}

/*
Set opposite corners if possible. "Free" = any negative value, so the
connectivity markers of wrap&zip (FREE_LEFT/RIGHT) count as free too.

Assert fails on already glued corners (has opposite).
*/
glue_corners :: proc(t: ^ct.Corner_Table, a, b: ct.Corner) {
	assert(a != b, "cannot glue corner with itself")
	assert(t.op[a] < 0, "corner is already glued")
	assert(t.op[b] < 0, "corner is already glued")

	t.op[a] = b
	t.op[b] = a
}

/*
Set all corners around v to have its c2v point to v. The corner c must be
adjacent to vertex v.
*/
set_ring :: proc(t: ^ct.Corner_Table, c: ct.Corner, v: ct.Vertex) {
	start, has_border := ct.rightmost(t^, c)
	if !has_border {start = c}

	curr := start
	for step := 0;; step += 1 {
		assert(step < len(t.pos), "Neighbours of vertex must be less than total # of vertices.")
		t.c2v[curr] = v

		next := ct.left(t^, curr)
		if next == start || next < 0 {break} 	// done full circle
		curr = next
	}
}

/*
Set border vertices to start from initial and increase by one each step.
*/
set_border :: proc(t: ^ct.Corner_Table, c: ct.Corner, initial: ct.Vertex, count: int) {
	current := c

	for i in 0 ..< count {
		set_ring(t, current, initial + ct.Vertex(i))

		next, found := ct.next_on_border(t^, current)
		assert(found, "border walk")

		current = next
	}

	r0, _ := ct.rightmost(t^, c)
	r1, _ := ct.rightmost(t^, current)

	assert(
		r0 == r1,
		fmt.tprintf(
			"border walk must be closed, v0 = %v, v1 = %v, c0 = %v, c1 = %v",
			t.c2v[r0],
			t.c2v[r1],
			c,
			current,
		),
	)
}

/***************************** Asserts ****************************************/

@(disabled = ODIN_DISABLE_ASSERT)
assert_corner_table_consistent :: proc(t: ct.Corner_Table) {
	for i in 0 ..< len(t.op) {
		c := ct.Corner(i)
		o := t.op[c]
		if o == ct.INVALID_CORNER {continue}

		assert(t.op[o] == c, "op is not symmetric")
		assert(t.c2v[next(c)] == t.c2v[prev(o)], "shared edge: start vertices differ")
		assert(t.c2v[prev(c)] == t.c2v[next(o)], "shared edge: end vertices differ")
	}
}

/*
After component is done, assert that triangles <first_tri, last_tri) have as many
border edges (= corners without opposite) as expected. Decoder knows
its own expected number (outer boundary + holes).
*/
@(disabled = ODIN_DISABLE_ASSERT)
assert_border_edges_count :: proc(t: ct.Corner_Table, first_tri, last_tri, expected: int) {
	actual := 0
	for i in 3 * first_tri ..< 3 * last_tri {
		if t.op[ct.Corner(i)] < 0 {actual += 1}
	}

	assert(
		actual == expected,
		fmt.tprintf("boundary edge count mismatch: expected %v, got %v", expected, actual),
	)
}
