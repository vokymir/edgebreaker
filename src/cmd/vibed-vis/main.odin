// Corner table viewer (raylib + Odin), single file.
//
//   project/
//   ├── main.odin               <- this file
//   └── corner_table/
//       └── corner_table.odin   <- your package
//
// Run:  odin run .
//
// Mouse: LMB drag = orbit/tilt | RMB, MMB or Shift+LMB drag = pan | wheel = zoom
// Keys:  arrows = orbit | R = reset view | 1..4 = demo mesh | Esc = quit
//        F faces | E edges | P vertex points | V vertex ids | T triangle ids
//        C corner ids | X vertex positions | N normal arrows | W winding arrows
//
// Search:      "/" (or click the box), type v12 / t5 / c17, Enter.
//              Highlights the element and centers the camera on it.
//              Enter on an empty box clears the highlight.
// Components:  a component = triangles connected through shared edges (op).
//              Right panel: click a name = select + center, drag a bar = opacity.
//              , and . = select previous/next component
//              G = focus selected (others become ghosts), H = solo selected
//              (others hidden), A = show all.
//
// To view your own mesh: fill `t` (a Corner_Table) in main() instead of
// calling load_demo(), then call analyze() once. Everything else only reads it.
package main

import ct "../../pkg/corner_table"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

Vec3 :: ct.Vec3

FONT :: 16
FONT_SM :: 14
FOVY :: f32(45)
FACE_SHRINK :: f32(0.94) // faces are drawn a bit smaller so edges stay visible
WIND_SCALE :: f32(0.5) // size of the inner winding loop relative to the triangle
GHOST_ALPHA :: f32(0.12) // opacity of "other" components after Focus
HIDDEN :: f32(0.01) // at or below this opacity a component is not drawn at all

FRONT_COLOR :: rl.Color{70, 120, 190, 255} // seen from the CCW side
BACK_COLOR :: rl.Color{190, 70, 90, 255} // seen from the CW side
WINDING_COLOR :: rl.Color{225, 130, 255, 255}
HILITE :: rl.Color{255, 215, 0, 255} // search result

/****************************** Toggles ***************************************/

Opt :: enum {
	Faces,
	Edges,
	Points,
	Vertex_Ids,
	Tri_Ids,
	Corner_Ids,
	Positions,
	Normals,
	Winding,
}

OPT_NAME := [Opt]string {
	.Faces      = "Faces",
	.Edges      = "Edges",
	.Points     = "Vertices (points)",
	.Vertex_Ids = "Vertex ids",
	.Tri_Ids    = "Triangle ids",
	.Corner_Ids = "Corner ids",
	.Positions  = "Vertex positions",
	.Normals    = "Orientation (normal)",
	.Winding    = "Winding (c -> next)",
}

OPT_KEY := [Opt]rl.KeyboardKey {
	.Faces      = .F,
	.Edges      = .E,
	.Points     = .P,
	.Vertex_Ids = .V,
	.Tri_Ids    = .T,
	.Corner_Ids = .C,
	.Positions  = .X,
	.Normals    = .N,
	.Winding    = .W,
}

DEMO_NAME := [?]string {
	"grid (open, has boundary)",
	"octahedron (closed)",
	"tetrahedron (closed)",
	"3 components (grid+octa+tetra)",
}

/****************************** View state ************************************/

Kind :: enum {
	None,
	Vertex,
	Triangle,
	Corner,
}

Sel :: struct {
	kind: Kind,
	id:   int,
}

View :: struct {
	opts:        [Opt]bool,
	orbit:       Orbit,
	demo:        int,

	// components: triangles connected through shared edges (op)
	tri_comp:    [dynamic]int, // component of each triangle
	vert_comp:   [dynamic]int, // component of each vertex (-1 = unused vertex)
	comp_tris:   [dynamic]int, // triangle count per component
	comp_alpha:  [dynamic]f32, // opacity per component, 0 = hidden
	sel_comp:    int, // selected component, -1 = none
	drag_comp:   int, // component whose slider is being dragged, -1 = none
	comp_scroll: int,
	reveal:      bool, // scroll the list so the selected component is visible

	// search
	typing:      bool,
	query_fresh: bool, // next typed char replaces the old text
	query:       [16]u8,
	query_len:   int,
	sel:         Sel,
	status_buf:  [96]u8,
	status:      string,
}

view_destroy :: proc(v: ^View) {
	delete(v.tri_comp)
	delete(v.vert_comp)
	delete(v.comp_tris)
	delete(v.comp_alpha)
}

/****************************** Building a table ******************************/

Edge :: [2]ct.Vertex

// Fill a corner table from positions + triangle indices (3 per triangle, CCW).
// Computes c2v, v2c and the opposite-corner table.
build :: proc(t: ^ct.Corner_Table, positions: []Vec3, tris: []int) {
	assert(len(tris) % 3 == 0)

	for p in positions {append(&t.pos, p)}
	for i in tris {append(&t.c2v, ct.Vertex(i))}
	resize(&t.op, len(tris))
	resize(&t.v2c, len(positions))
	for &o in t.op {o = ct.INVALID_CORNER}
	for &c in t.v2c {c = ct.INVALID_CORNER}

	edges := make(map[Edge]ct.Corner)
	defer delete(edges)

	for ci in 0 ..< len(tris) {
		c := ct.Corner(ci)
		v := t.c2v[c]
		if t.v2c[v] < 0 {t.v2c[v] = c}

		// edge opposite to corner c runs from vertex(next) to vertex(prev)
		a := t.c2v[ct.next(c)]
		b := t.c2v[ct.prev(c)]
		if other, found := edges[Edge{b, a}]; found { 	// same edge, reversed => neighbour
			t.op[c] = other
			t.op[other] = c
		} else {
			edges[Edge{a, b}] = c
		}
	}
}

add_grid :: proc(verts: ^[dynamic]Vec3, tris: ^[dynamic]int, off: Vec3) {
	NX, NY :: 3, 2
	base := len(verts^)
	for j in 0 ..= NY {
		for i in 0 ..= NX {
			append(verts, Vec3{f32(i) - NX / 2.0, f32(j) - NY / 2.0, 0} + off)
		}
	}
	for j in 0 ..< NY {
		for i in 0 ..< NX {
			a := base + j * (NX + 1) + i
			b := a + 1
			d := a + (NX + 1)
			c := d + 1
			append(tris, a, b, c, a, c, d)
		}
	}
}

add_octahedron :: proc(verts: ^[dynamic]Vec3, tris: ^[dynamic]int, off: Vec3) {
	base := len(verts^)
	append(
		verts,
		Vec3{1, 0, 0} + off,
		Vec3{-1, 0, 0} + off,
		Vec3{0, 1, 0} + off,
		Vec3{0, -1, 0} + off,
		Vec3{0, 0, 1} + off,
		Vec3{0, 0, -1} + off,
	)
	for sx in 0 ..< 2 {
		for sy in 0 ..< 2 {
			for sz in 0 ..< 2 {
				a, b, c := sx, 2 + sy, 4 + sz
				if (sx + sy + sz) % 2 == 1 {b, c = c, b} 	// keep CCW seen from outside
				append(tris, base + a, base + b, base + c)
			}
		}
	}
}

add_tetrahedron :: proc(verts: ^[dynamic]Vec3, tris: ^[dynamic]int, off: Vec3) {
	base := len(verts^)
	append(
		verts,
		Vec3{1, 1, 1} + off,
		Vec3{1, -1, -1} + off,
		Vec3{-1, 1, -1} + off,
		Vec3{-1, -1, 1} + off,
	)
	append(
		tris,
		base + 0,
		base + 1,
		base + 2,
		base + 0,
		base + 2,
		base + 3,
		base + 0,
		base + 3,
		base + 1,
		base + 1,
		base + 3,
		base + 2,
	)
}

load_demo :: proc(t: ^ct.Corner_Table, which: int) {
	clear(&t.pos)
	clear(&t.c2v)
	clear(&t.op)
	clear(&t.v2c)

	verts := make([dynamic]Vec3, context.temp_allocator)
	tris := make([dynamic]int, context.temp_allocator)

	switch which {
	case 0:
		add_grid(&verts, &tris, {0, 0, 0})
	case 1:
		add_octahedron(&verts, &tris, {0, 0, 0})
	case 2:
		add_tetrahedron(&verts, &tris, {0, 0, 0})
	case 3:
		add_grid(&verts, &tris, {-4.5, 0, 0})
		add_octahedron(&verts, &tris, {0, 0, 0})
		add_tetrahedron(&verts, &tris, {3.5, 0, 0})
	}

	build(t, verts[:], tris[:])
}

/****************************** Components ************************************/

// Flood-fill triangles over op to find components. Call after the table changed.
analyze :: proc(v: ^View, t: ^ct.Corner_Table) {
	n_tri := len(t.c2v) / 3

	clear(&v.tri_comp)
	clear(&v.vert_comp)
	clear(&v.comp_tris)
	clear(&v.comp_alpha)
	resize(&v.tri_comp, n_tri)
	resize(&v.vert_comp, len(t.pos))
	for &c in v.tri_comp {c = -1}
	for &c in v.vert_comp {c = -1}

	stack := make([dynamic]int, context.temp_allocator)
	for seed in 0 ..< n_tri {
		if v.tri_comp[seed] >= 0 {continue}

		id := len(v.comp_tris)
		append(&v.comp_tris, 0)
		v.tri_comp[seed] = id
		append(&stack, seed)

		for len(stack) > 0 {
			ti := pop(&stack)
			v.comp_tris[id] += 1
			for k in 0 ..< 3 {
				o := t.op[3 * ti + k]
				if o < 0 {continue}
				nt := int(ct.c2t(o))
				if v.tri_comp[nt] < 0 {
					v.tri_comp[nt] = id
					append(&stack, nt)
				}
			}
		}
	}

	for ci in 0 ..< len(t.c2v) {
		v.vert_comp[t.c2v[ci]] = v.tri_comp[ci / 3]
	}

	resize(&v.comp_alpha, len(v.comp_tris))
	for &a in v.comp_alpha {a = 1}

	v.sel_comp = -1
	v.drag_comp = -1
	v.comp_scroll = 0
	v.sel = Sel{}
	v.status = ""
}

vert_alpha :: proc(v: ^View, vi: int) -> f32 {
	c := v.vert_comp[vi]
	return c < 0 ? 1 : v.comp_alpha[c]
}

comp_all :: proc(v: ^View) {
	for &a in v.comp_alpha {a = 1}
}

// selected component fully visible, every other component gets `others` opacity
comp_focus :: proc(v: ^View, others: f32) {
	if v.sel_comp < 0 {
		v.status = "select a component first"
		return
	}
	for &a, i in v.comp_alpha {a = i == v.sel_comp ? 1 : others}
}

select_comp :: proc(v: ^View, t: ^ct.Corner_Table, c: int, center: bool) {
	v.sel_comp = c
	v.reveal = true
	if center && c >= 0 {
		f := frame(t, v, c)
		v.orbit.target = f.target
		v.orbit.dist = f.dist
	}
}

/****************************** Camera ****************************************/

Orbit :: struct {
	target:     Vec3,
	yaw, pitch: f32,
	dist:       f32,
}

orbit_dir :: proc(o: Orbit) -> Vec3 {
	return {
		math.cos(o.pitch) * math.sin(o.yaw),
		math.sin(o.pitch),
		math.cos(o.pitch) * math.cos(o.yaw),
	}
}

to_camera :: proc(o: Orbit) -> rl.Camera3D {
	return {
		position = o.target + orbit_dir(o) * o.dist,
		target = o.target,
		up = {0, 1, 0},
		fovy = FOVY,
		projection = .PERSPECTIVE,
	}
}

bbox_grow :: proc(lo, hi: ^Vec3, p: Vec3) {
	for i in 0 ..< 3 {
		lo[i] = min(lo[i], p[i])
		hi[i] = max(hi[i], p[i])
	}
}

// Orbit that frames the whole mesh (comp = -1) or one component.
frame :: proc(t: ^ct.Corner_Table, v: ^View, comp := -1) -> Orbit {
	o := Orbit {
		yaw   = 0.5,
		pitch = 0.45,
		dist  = 6,
	}

	lo := Vec3{math.F32_MAX, math.F32_MAX, math.F32_MAX}
	hi := -lo
	if comp < 0 {
		for p in t.pos {bbox_grow(&lo, &hi, p)}
	} else {
		for ci in 0 ..< len(t.c2v) {
			if v.tri_comp[ci / 3] == comp {bbox_grow(&lo, &hi, t.pos[t.c2v[ci]])}
		}
	}
	if lo.x > hi.x {return o} 	// nothing to frame

	o.target = (lo + hi) / 2
	radius := max(linalg.length(hi - lo) / 2, 0.001)
	o.dist = 1.3 * radius / math.tan(FOVY * math.RAD_PER_DEG / 2)
	return o
}

update_orbit :: proc(o: ^Orbit, mouse_ok, keys_ok: bool) {
	if mouse_ok {
		d := rl.GetMouseDelta()
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		pan :=
			rl.IsMouseButtonDown(.RIGHT) ||
			rl.IsMouseButtonDown(.MIDDLE) ||
			(shift && rl.IsMouseButtonDown(.LEFT))

		if pan {
			fwd := -orbit_dir(o^)
			right := linalg.normalize0(linalg.cross(fwd, Vec3{0, 1, 0}))
			up := linalg.cross(right, fwd)
			// world units per pixel at the target distance
			k := 2 * o.dist * math.tan(FOVY * math.RAD_PER_DEG / 2) / f32(rl.GetScreenHeight())
			o.target += (up * d.y - right * d.x) * k
		} else if rl.IsMouseButtonDown(.LEFT) {
			o.yaw -= d.x * 0.008
			o.pitch += d.y * 0.008
		}
		o.dist *= math.pow(f32(0.9), rl.GetMouseWheelMove())
	}

	if keys_ok {
		dt := rl.GetFrameTime()
		if rl.IsKeyDown(.LEFT) {o.yaw -= 1.5 * dt}
		if rl.IsKeyDown(.RIGHT) {o.yaw += 1.5 * dt}
		if rl.IsKeyDown(.UP) {o.pitch += 1.5 * dt}
		if rl.IsKeyDown(.DOWN) {o.pitch -= 1.5 * dt}
	}

	o.pitch = clamp(o.pitch, -1.55, 1.55)
	o.dist = max(o.dist, 0.01)
}

/****************************** Geometry helpers ******************************/

shade :: proc(c: rl.Color, k, alpha: f32) -> rl.Color {
	return {u8(f32(c.r) * k), u8(f32(c.g) * k), u8(f32(c.b) * k), u8(255 * alpha)}
}

// arrow with a cone head; head length is a fraction of the arrow length
arrow :: proc(from, to: Vec3, color: rl.Color) {
	dir := linalg.normalize0(to - from)
	head := linalg.length(to - from) * 0.25
	base := to - dir * head
	rl.DrawLine3D(from, base, color)
	rl.DrawCylinderEx(base, to, head * 0.4, 0, 8, color)
}

// the 3 positions of triangle ti, in corner order (CCW)
tri_pts :: proc(t: ^ct.Corner_Table, ti: int) -> (a, b, c: Vec3) {
	c0 := ct.Corner(3 * ti)
	return ct.pos(t^, c0), ct.pos(t^, ct.next(c0)), ct.pos(t^, ct.prev(c0))
}

// average edge length of triangle ti (1 if there is no such triangle)
tri_size :: proc(t: ^ct.Corner_Table, ti: int) -> f32 {
	if ti < 0 || 3 * ti + 2 >= len(t.c2v) {return 1}
	a, b, c := tri_pts(t, ti)
	return (linalg.length(b - a) + linalg.length(c - b) + linalg.length(a - c)) / 3
}

// the region of corner c: its vertex plus a bit of both incident edges
corner_wedge :: proc(t: ^ct.Corner_Table, c: ct.Corner) -> (p, q0, q1: Vec3) {
	p = ct.pos(t^, c)
	q0 = p + (ct.pos(t^, ct.next(c)) - p) * 0.4
	q1 = p + (ct.pos(t^, ct.prev(c)) - p) * 0.4
	return
}

// world -> screen; ok is false if the point is behind the camera
project :: proc(p: Vec3, cam: rl.Camera3D) -> (s: rl.Vector2, ok: bool) {
	fwd := linalg.normalize0(cam.target - cam.position)
	if linalg.dot(p - cam.position, fwd) < 0.01 {return}
	return rl.GetWorldToScreen(p, cam), true
}

// Where a label for the selected element goes, how big the element is, and
// which component it belongs to.
sel_point :: proc(t: ^ct.Corner_Table, v: ^View) -> (p: Vec3, size: f32, comp: int) {
	ti := 0
	switch v.sel.kind {
	case .None:
		return
	case .Vertex:
		vi := ct.Vertex(v.sel.id)
		p = t.pos[vi]
		comp = v.vert_comp[v.sel.id]
		if c := ct.v2c(t^, vi); c >= 0 {ti = int(ct.c2t(c))}
	case .Triangle:
		ti = v.sel.id
		a, b, c := tri_pts(t, ti)
		p = (a + b + c) / 3
		comp = v.tri_comp[ti]
	case .Corner:
		c := ct.Corner(v.sel.id)
		ti = int(ct.c2t(c))
		a, b, cc := tri_pts(t, ti)
		cen := (a + b + cc) / 3
		pc := ct.pos(t^, c)
		p = pc + (cen - pc) * 0.3 // slightly inside the triangle, near its vertex
		comp = v.tri_comp[ti]
	}
	size = tri_size(t, ti)
	return
}

/****************************** Search ****************************************/

search_rect :: proc() -> rl.Rectangle {
	return {UI_X + 10, SEARCH_Y, UI_W - 20, 26}
}

// Move the camera to the selected element and select its component.
focus_selection :: proc(v: ^View, t: ^ct.Corner_Table) {
	p, size, comp := sel_point(t, v)
	v.orbit.target = p
	v.orbit.dist = min(v.orbit.dist, size * 6) // zoom in if we are far away
	if comp >= 0 {
		v.sel_comp = comp
		v.reveal = true
	}
}

// Parse the query ("v12", "t5", "c17"; only the first letter and the digits matter).
search :: proc(v: ^View, t: ^ct.Corner_Table) {
	if v.query_len == 0 {
		v.sel = Sel{}
		v.status = ""
		return
	}

	kind := Kind.None
	id, digits := 0, 0
	for i in 0 ..< v.query_len {
		ch := v.query[i]
		switch {
		case ch >= '0' && ch <= '9':
			id = id * 10 + int(ch - '0')
			digits += 1
		case kind == .None:
			switch ch {
			case 'v', 'V':
				kind = .Vertex
			case 't', 'T':
				kind = .Triangle
			case 'c', 'C':
				kind = .Corner
			}
		}
	}
	if kind == .None || digits == 0 {
		v.status = "type v<id>, t<id> or c<id>"
		return
	}

	count := 0
	name := ""
	switch kind {
	case .None:
	case .Vertex:
		count, name = len(t.pos), "vertex"
	case .Triangle:
		count, name = len(t.c2v) / 3, "triangle"
	case .Corner:
		count, name = len(t.c2v), "corner"
	}
	if id >= count {
		v.status = fmt.bprintf(v.status_buf[:], "no %s %d (mesh has %d)", name, id, count)
		return
	}

	v.sel = Sel {
		kind = kind,
		id   = id,
	}
	v.status = ""
	focus_selection(v, t)
}

start_typing :: proc(v: ^View) {
	v.typing = true
	v.query_fresh = true
}

update_search :: proc(v: ^View, t: ^ct.Corner_Table) {
	if rl.IsMouseButtonPressed(.LEFT) {
		inside := rl.CheckCollisionPointRec(rl.GetMousePosition(), search_rect())
		if inside && !v.typing {
			start_typing(v)
		} else if !inside {
			v.typing = false
		}
	}

	// the char queue is drained every frame so stale keystrokes never show up
	for {
		ch := rl.GetCharPressed()
		if ch == 0 {break}

		if !v.typing {
			if ch == '/' {start_typing(v)}
			continue
		}
		is_alnum :=
			(ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
		if !is_alnum {continue}
		if v.query_fresh {
			v.query_len = 0
			v.query_fresh = false
		}
		if v.query_len < len(v.query) {
			v.query[v.query_len] = u8(ch)
			v.query_len += 1
		}
	}

	if !v.typing {return}

	if rl.IsKeyPressed(.BACKSPACE) {
		if v.query_fresh {
			v.query_len = 0
			v.query_fresh = false
		} else if v.query_len > 0 {
			v.query_len -= 1
		}
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		v.typing = false
		search(v, t)
	}
}

/****************************** Scene (3D) ************************************/

// Opaque components are drawn first (depth writes on), partially transparent
// ones afterwards without depth writes so they blend over what is behind them.
in_pass :: proc(alpha: f32, opaque: bool) -> bool {
	if alpha <= HIDDEN {return false}
	return (alpha >= 0.999) == opaque
}

draw_scene :: proc(t: ^ct.Corner_Table, v: ^View, cam: rl.Camera3D) {
	draw_pass(t, v, cam, true)
	draw_selection(t, v)

	rlgl.DisableDepthMask()
	draw_pass(t, v, cam, false)
	rlgl.EnableDepthMask()
}

draw_pass :: proc(t: ^ct.Corner_Table, v: ^View, cam: rl.Camera3D, opaque: bool) {
	opts := v.opts

	for ti in 0 ..< len(t.c2v) / 3 {
		alpha := v.comp_alpha[v.tri_comp[ti]]
		if !in_pass(alpha, opaque) {continue}

		a, b, c := tri_pts(t, ti)
		cen := (a + b + c) / 3
		n := linalg.normalize0(linalg.cross(b - a, c - a))

		if opts[.Faces] {
			// headlight shading; with back-face culling each side gets its own colour
			facing := abs(linalg.dot(n, linalg.normalize0(cam.position - cen)))
			k := min(0.45 + 0.55 * facing, 1)
			a2 := cen + (a - cen) * FACE_SHRINK
			b2 := cen + (b - cen) * FACE_SHRINK
			c2 := cen + (c - cen) * FACE_SHRINK
			rl.DrawTriangle3D(a2, b2, c2, shade(FRONT_COLOR, k, alpha))
			rl.DrawTriangle3D(a2, c2, b2, shade(BACK_COLOR, k, alpha))
		}

		if opts[.Normals] {
			arrow(cen, cen + n * (tri_size(t, ti) * 0.5), rl.Fade(rl.GREEN, alpha))
		}

		if opts[.Winding] {
			// small CCW loop inside the triangle: corner c -> next(c)
			for k in 0 ..< 3 {
				corner := ct.Corner(3 * ti + k)
				p0 := cen + (ct.pos(t^, corner) - cen) * WIND_SCALE
				p1 := cen + (ct.pos(t^, ct.next(corner)) - cen) * WIND_SCALE
				arrow(p0 + (p1 - p0) * 0.15, p0 + (p1 - p0) * 0.85, rl.Fade(WINDING_COLOR, alpha))
			}
		}
	}

	if opts[.Edges] {
		for ci in 0 ..< len(t.c2v) {
			alpha := v.comp_alpha[v.tri_comp[ci / 3]]
			if !in_pass(alpha, opaque) {continue}

			c := ct.Corner(ci)
			opp := ct.op(t^, c)
			if opp >= 0 && opp < c {continue} 	// interior edge: drawn from its other side
			a := ct.pos(t^, ct.next(c))
			b := ct.pos(t^, ct.prev(c))
			rl.DrawLine3D(a, b, rl.Fade(opp < 0 ? rl.RED : rl.LIGHTGRAY, alpha)) // red = boundary
		}
	}

	if opts[.Points] {
		radius := v.orbit.dist * 0.006 // roughly constant size on screen
		for p, i in t.pos {
			alpha := vert_alpha(v, i)
			if !in_pass(alpha, opaque) {continue}
			rl.DrawSphereEx(p, radius, 8, 8, rl.Fade(rl.YELLOW, alpha))
		}
	}
}

// translucent triangle slightly above the surface, visible from both sides
overlay :: proc(a, b, c: Vec3, eps: f32, color: rl.Color) {
	n := linalg.normalize0(linalg.cross(b - a, c - a)) * eps
	rl.DrawTriangle3D(a + n, b + n, c + n, color)
	rl.DrawTriangle3D(a - n, c - n, b - n, color)
}

// Highlight of the searched element. Drawn at full strength even if its
// component is ghosted or hidden.
draw_selection :: proc(t: ^ct.Corner_Table, v: ^View) {
	if v.sel.kind == .None {return}

	pulse := 0.65 + 0.35 * math.sin(f32(rl.GetTime()) * 6)
	col := rl.Fade(HILITE, pulse)
	eps := v.orbit.dist * 0.0015
	thick := v.orbit.dist * 0.002

	switch v.sel.kind {
	case .None:
	case .Vertex:
		rl.DrawSphereEx(t.pos[v.sel.id], v.orbit.dist * 0.014, 12, 12, col)
	case .Triangle:
		a, b, c := tri_pts(t, v.sel.id)
		overlay(a, b, c, eps, col)
		rl.DrawCylinderEx(a, b, thick, thick, 6, HILITE)
		rl.DrawCylinderEx(b, c, thick, thick, 6, HILITE)
		rl.DrawCylinderEx(c, a, thick, thick, 6, HILITE)
	case .Corner:
		p, q0, q1 := corner_wedge(t, ct.Corner(v.sel.id))
		overlay(p, q0, q1, eps, col)
		rl.DrawCylinderEx(p, q0, thick, thick, 6, HILITE)
		rl.DrawCylinderEx(p, q1, thick, thick, 6, HILITE)
	}
}

/****************************** Labels (2D overlay) ***************************/

// text with a backing box so it is readable over faces
label :: proc(
	text: cstring,
	x, y: i32,
	color: rl.Color,
	alpha: f32 = 1,
	centered := false,
	bg: rl.Color = rl.BLACK,
	bg_alpha: f32 = 0.6,
) {
	x := x
	w := rl.MeasureText(text, FONT)
	if centered {x -= w / 2}
	rl.DrawRectangle(x - 2, y - 1, w + 4, FONT + 2, rl.Fade(bg, bg_alpha * alpha))
	rl.DrawText(text, x, y, FONT, rl.Fade(color, alpha))
}

draw_labels :: proc(t: ^ct.Corner_Table, v: ^View, cam: rl.Camera3D) {
	opts := v.opts

	if opts[.Vertex_Ids] || opts[.Positions] {
		for p, i in t.pos {
			va := vert_alpha(v, i)
			if va <= HIDDEN {continue}
			s := project(p, cam) or_continue
			x, y := i32(s.x) + 8, i32(s.y)
			if opts[.Vertex_Ids] {
				label(fmt.ctprintf("v%d", i), x, y - FONT - 6, rl.YELLOW, va)
			}
			if opts[.Positions] {
				label(
					fmt.ctprintf("(%.2f, %.2f, %.2f)", p.x, p.y, p.z),
					x,
					y + 6,
					rl.LIGHTGRAY,
					va,
				)
			}
		}
	}

	if opts[.Tri_Ids] || opts[.Corner_Ids] {
		for ti in 0 ..< len(t.c2v) / 3 {
			ca := v.comp_alpha[v.tri_comp[ti]]
			if ca <= HIDDEN {continue}

			a, b, c := tri_pts(t, ti)
			cen := (a + b + c) / 3
			n := linalg.cross(b - a, c - a)
			// labels of triangles facing away from the camera are dimmed
			alpha: f32 = (linalg.dot(n, cam.position - cen) > 0 ? 1 : 0.35) * ca

			if opts[.Tri_Ids] {
				if s, ok := project(cen, cam); ok {
					label(
						fmt.ctprintf("t%d", ti),
						i32(s.x),
						i32(s.y) - FONT / 2,
						rl.SKYBLUE,
						alpha,
						true,
					)
				}
			}

			if opts[.Corner_Ids] {
				for k in 0 ..< 3 {
					corner := ct.Corner(3 * ti + k)
					p := ct.pos(t^, corner)
					q := p + (cen - p) * 0.3 // slightly inside the triangle, near its vertex
					if s, ok := project(q, cam); ok {
						label(
							fmt.ctprintf("c%d", int(corner)),
							i32(s.x),
							i32(s.y) - FONT / 2,
							rl.ORANGE,
							alpha,
							true,
						)
					}
				}
			}
		}
	}

	// the searched element is always labelled, on top of everything else
	if v.sel.kind != .None {
		p, _, _ := sel_point(t, v)
		if s, ok := project(p, cam); ok {
			x, y := i32(s.x), i32(s.y)
			switch v.sel.kind {
			case .None:
			case .Vertex:
				label(
					fmt.ctprintf("v%d", v.sel.id),
					x + 8,
					y - FONT - 6,
					rl.BLACK,
					1,
					false,
					HILITE,
					1,
				)
			case .Triangle:
				label(fmt.ctprintf("t%d", v.sel.id), x, y - FONT / 2, rl.BLACK, 1, true, HILITE, 1)
			case .Corner:
				label(fmt.ctprintf("c%d", v.sel.id), x, y - FONT / 2, rl.BLACK, 1, true, HILITE, 1)
			}
		}
	}
}

/****************************** UI: left panel ********************************/

UI_X, UI_Y, UI_W, UI_ROW :: 10, 10, 250, 22
SEARCH_Y :: 312
LEFT_H :: 480

left_rect :: proc() -> rl.Rectangle {
	return {UI_X, UI_Y, UI_W, LEFT_H}
}

// the corner-table data of the selected element, up to 4 lines
info_lines :: proc(t: ^ct.Corner_Table, v: ^View) -> (lines: [4]cstring) {
	switch v.sel.kind {
	case .None:
	case .Vertex:
		vi := ct.Vertex(v.sel.id)
		p := t.pos[vi]
		lines[0] = fmt.ctprintf("v%d   component %d", v.sel.id, v.vert_comp[v.sel.id])
		lines[1] = fmt.ctprintf("pos (%.3f, %.3f, %.3f)", p.x, p.y, p.z)
		lines[2] = fmt.ctprintf("v2c = c%d", int(ct.v2c(t^, vi)))
	case .Triangle:
		c0 := int(ct.Corner(3 * v.sel.id))
		lines[0] = fmt.ctprintf("t%d   component %d", v.sel.id, v.tri_comp[v.sel.id])
		lines[1] = fmt.ctprintf("corners c%d c%d c%d", c0, c0 + 1, c0 + 2)
		lines[2] = fmt.ctprintf(
			"verts v%d v%d v%d",
			int(t.c2v[c0]),
			int(t.c2v[c0 + 1]),
			int(t.c2v[c0 + 2]),
		)
		lines[3] = fmt.ctprintf(
			"op %d %d %d (-1 = boundary)",
			int(t.op[c0]),
			int(t.op[c0 + 1]),
			int(t.op[c0 + 2]),
		)
	case .Corner:
		c := ct.Corner(v.sel.id)
		o := ct.op(t^, c)
		lines[0] = fmt.ctprintf("c%d   component %d", v.sel.id, v.tri_comp[int(ct.c2t(c))])
		lines[1] = fmt.ctprintf("triangle t%d   vertex v%d", int(ct.c2t(c)), int(ct.c2v(t^, c)))
		lines[2] = fmt.ctprintf("next c%d   prev c%d", int(ct.next(c)), int(ct.prev(c)))
		if o >= 0 {
			lines[3] = fmt.ctprintf("op = c%d  (t%d)", int(o), int(ct.c2t(o)))
		} else {
			lines[3] = "op = none (boundary)"
		}
	}
	return
}

draw_ui :: proc(t: ^ct.Corner_Table, v: ^View) {
	rl.DrawRectangleRec(left_rect(), rl.Fade(rl.BLACK, 0.55))

	// ---- toggles
	mouse := rl.GetMousePosition()
	for opt in Opt {
		y := i32(UI_Y + 10 + UI_ROW * int(opt))
		row := rl.Rectangle{UI_X, f32(y) - 3, UI_W, UI_ROW}
		box := rl.Rectangle{UI_X + 10, f32(y), 16, 16}

		if rl.IsMouseButtonPressed(.LEFT) && rl.CheckCollisionPointRec(mouse, row) {
			v.opts[opt] = !v.opts[opt]
		}
		rl.DrawRectangleLinesEx(box, 2, rl.RAYWHITE)
		if v.opts[opt] {
			rl.DrawRectangle(UI_X + 14, y + 4, 8, 8, rl.RAYWHITE)
		}
		rl.DrawText(
			fmt.ctprintf("%s  [%c]", OPT_NAME[opt], rune(OPT_KEY[opt])),
			UI_X + 36,
			y,
			FONT,
			rl.RAYWHITE,
		)
	}

	// ---- mesh stats
	y := i32(UI_Y + 10 + UI_ROW * len(Opt)) + 14
	rl.DrawText(
		fmt.ctprintf("mesh [1-4]: %s", DEMO_NAME[v.demo]),
		UI_X + 10,
		y,
		FONT_SM,
		rl.RAYWHITE,
	)
	rl.DrawText(
		fmt.ctprintf(
			"V %d   T %d   C %d   comps %d",
			len(t.pos),
			len(t.c2v) / 3,
			len(t.c2v),
			len(v.comp_tris),
		),
		UI_X + 10,
		y + 22,
		FONT_SM,
		rl.LIGHTGRAY,
	)

	// ---- search box
	rl.DrawText("Search  ( / )    v12   t5   c17", UI_X + 10, SEARCH_Y - 20, FONT_SM, rl.GRAY)
	box := search_rect()
	rl.DrawRectangleRec(box, v.typing ? rl.Color{45, 45, 75, 255} : rl.Color{30, 30, 40, 255})
	rl.DrawRectangleLinesEx(box, 1, v.typing ? HILITE : rl.GRAY)
	tx, ty := i32(box.x) + 8, i32(box.y) + 5
	if v.query_len == 0 && !v.typing {
		rl.DrawText("click or press /", tx, ty, FONT, rl.DARKGRAY)
	} else {
		text := fmt.ctprintf("%s", string(v.query[:v.query_len]))
		w := rl.MeasureText(text, FONT)
		if v.typing && v.query_fresh && v.query_len > 0 {
			rl.DrawRectangle(tx - 2, ty - 1, w + 4, FONT + 2, rl.Color{70, 100, 170, 255}) // "selected" text
		}
		rl.DrawText(text, tx, ty, FONT, rl.RAYWHITE)
		if v.typing && !v.query_fresh && int(rl.GetTime() * 2) % 2 == 0 {
			rl.DrawRectangle(tx + w + 1, ty, 2, FONT, rl.RAYWHITE) // caret
		}
	}

	// ---- status + info about the selected element
	iy := i32(box.y + box.height) + 10
	if len(v.status) > 0 {
		rl.DrawText(
			fmt.ctprintf("%s", v.status),
			UI_X + 10,
			iy,
			FONT_SM,
			rl.Color{255, 130, 130, 255},
		)
		iy += 22
	}
	lines := info_lines(t, v)
	for l, i in lines {
		if l == nil {continue}
		rl.DrawText(l, UI_X + 10, iy, FONT_SM, i == 0 ? HILITE : rl.RAYWHITE)
		iy += 20
	}

	// ---- help
	h := rl.GetScreenHeight()
	rl.DrawText(
		"faces: blue = front (CCW side), red = back   |   red edge = boundary (op < 0)",
		10,
		h - 70,
		FONT_SM,
		rl.GRAY,
	)
	rl.DrawText(
		"LMB orbit | RMB / Shift+LMB pan | wheel zoom | arrows orbit | R reset view | Esc quit",
		10,
		h - 48,
		FONT_SM,
		rl.GRAY,
	)
	rl.DrawText(
		"components:  , .  select prev/next | G focus | H solo | A show all",
		10,
		h - 26,
		FONT_SM,
		rl.GRAY,
	)
}

/****************************** UI: component panel ***************************/

COMP_W :: 330
COMP_ROW :: 26
COMP_TOP :: 96 // where the list starts inside the panel

comp_layout :: proc(v: ^View) -> (panel: rl.Rectangle, rows: int) {
	sw, sh := int(rl.GetScreenWidth()), int(rl.GetScreenHeight())
	rows = min(len(v.comp_tris), max((sh - 20 - COMP_TOP - 80) / COMP_ROW, 1))
	panel = {f32(sw - COMP_W - 10), 10, COMP_W, f32(COMP_TOP + rows * COMP_ROW + 10)}
	return
}

button :: proc(r: rl.Rectangle, text: cstring) -> bool {
	hover := rl.CheckCollisionPointRec(rl.GetMousePosition(), r)
	rl.DrawRectangleRec(r, hover ? rl.Color{90, 90, 120, 255} : rl.Color{55, 55, 75, 255})
	rl.DrawRectangleLinesEx(r, 1, rl.GRAY)
	w := rl.MeasureText(text, FONT_SM)
	rl.DrawText(
		text,
		i32(r.x + r.width / 2) - w / 2,
		i32(r.y + r.height / 2) - FONT_SM / 2,
		FONT_SM,
		rl.RAYWHITE,
	)
	return hover && rl.IsMouseButtonPressed(.LEFT)
}

draw_components :: proc(t: ^ct.Corner_Table, v: ^View) {
	n := len(v.comp_tris)
	panel, rows := comp_layout(v)
	rl.DrawRectangleRec(panel, rl.Fade(rl.BLACK, 0.55))
	mouse := rl.GetMousePosition()
	px, py := i32(panel.x), i32(panel.y)

	sel := v.sel_comp >= 0 ? fmt.tprintf("#%d", v.sel_comp) : "none"
	rl.DrawText(
		fmt.ctprintf("Components: %d     selected: %s", n, sel),
		px + 10,
		py + 8,
		FONT,
		rl.RAYWHITE,
	)

	bw := (panel.width - 20 - 12) / 3
	b0 := rl.Rectangle{panel.x + 10, panel.y + 34, bw, 24}
	b1 := rl.Rectangle{b0.x + bw + 6, b0.y, bw, 24}
	b2 := rl.Rectangle{b1.x + bw + 6, b0.y, bw, 24}
	if button(b0, "All [A]") {comp_all(v)}
	if button(b1, "Focus [G]") {comp_focus(v, GHOST_ALPHA)}
	if button(b2, "Solo [H]") {comp_focus(v, 0)}
	rl.DrawText("click name: select | drag bar: opacity", px + 10, py + 66, FONT_SM, rl.GRAY)

	// scrolling: wheel over the panel, and keep the selected component in view
	if rl.CheckCollisionPointRec(mouse, panel) {
		w := rl.GetMouseWheelMove()
		if w > 0 {v.comp_scroll -= 1}
		if w < 0 {v.comp_scroll += 1}
	}
	if v.reveal && v.sel_comp >= 0 {
		if v.sel_comp < v.comp_scroll {
			v.comp_scroll = v.sel_comp
		} else if v.sel_comp >= v.comp_scroll + rows {
			v.comp_scroll = v.sel_comp - rows + 1
		}
	}
	v.reveal = false
	v.comp_scroll = clamp(v.comp_scroll, 0, max(n - rows, 0))
	if n > rows {
		rl.DrawText(
			fmt.ctprintf("%d-%d of %d (wheel)", v.comp_scroll + 1, v.comp_scroll + rows, n),
			px + 10,
			py + 82,
			FONT_SM,
			rl.GRAY,
		)
	}

	for k in 0 ..< rows {
		i := v.comp_scroll + k
		ry := f32(py) + f32(COMP_TOP + k * COMP_ROW)
		name := rl.Rectangle{panel.x + 6, ry, 124, COMP_ROW - 2}
		bar := rl.Rectangle{panel.x + 140, ry + 6, 130, 14}
		hit := rl.Rectangle{bar.x - 3, ry, bar.width + 6, COMP_ROW - 2}

		if rl.IsMouseButtonPressed(.LEFT) {
			if rl.CheckCollisionPointRec(mouse, name) {
				select_comp(v, t, i, true)
			} else if rl.CheckCollisionPointRec(mouse, hit) {
				v.drag_comp = i
			}
		}
		if v.drag_comp == i && rl.IsMouseButtonDown(.LEFT) {
			a := clamp((mouse.x - bar.x) / bar.width, 0, 1)
			if a < 0.03 {a = 0}
			if a > 0.97 {a = 1}
			v.comp_alpha[i] = a
		}

		if i == v.sel_comp {
			rl.DrawRectangleRec(name, rl.Color{70, 95, 150, 220})
		}
		rl.DrawText(
			fmt.ctprintf("#%d  (%dt)", i, v.comp_tris[i]),
			i32(name.x) + 4,
			i32(ry) + 4,
			FONT,
			rl.RAYWHITE,
		)

		rl.DrawRectangleRec(bar, rl.Color{35, 35, 45, 255})
		rl.DrawRectangleRec(
			{bar.x, bar.y, bar.width * v.comp_alpha[i], bar.height},
			rl.Color{120, 170, 255, 255},
		)
		rl.DrawRectangleLinesEx(bar, 1, rl.GRAY)
		rl.DrawText(
			fmt.ctprintf("%.2f", v.comp_alpha[i]),
			i32(bar.x + bar.width) + 8,
			i32(ry) + 5,
			FONT_SM,
			rl.LIGHTGRAY,
		)
	}

	if !rl.IsMouseButtonDown(.LEFT) {v.drag_comp = -1}
}

/****************************** Main ******************************************/

reload :: proc(t: ^ct.Corner_Table, v: ^View, which: int) {
	v.demo = which
	ct.load(t, "../../../assets/medium/suzanne_od_simona.obj")
	// ct.load(t, "../ebk/decoded.obj")
	// load_demo(t, which)
	analyze(v, t)
	v.orbit = frame(t, v)
}

main :: proc() {
	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 800, "corner table viewer")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(rl.KeyboardKey(0)) // Esc leaves the search box, so we handle quitting ourselves

	t: ct.Corner_Table
	ct.init(&t)
	defer ct.destroy(&t)

	v: View
	defer view_destroy(&v)
	for opt in Opt {v.opts[opt] = true}
	v.opts[.Positions] = false

	reload(&t, &v, 0) // <- replace with your own table, then call analyze() and frame()

	demo_keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE, .FOUR}

	for !rl.WindowShouldClose() {
		// ---- input
		if rl.IsKeyPressed(.ESCAPE) {
			if v.typing {v.typing = false} else {break}
		}

		update_search(&v, &t)

		if !v.typing {
			for opt in Opt {
				if rl.IsKeyPressed(OPT_KEY[opt]) {v.opts[opt] = !v.opts[opt]}
			}
			for key, i in demo_keys {
				if rl.IsKeyPressed(key) {reload(&t, &v, i)}
			}
			if rl.IsKeyPressed(.R) {v.orbit = frame(&t, &v)}

			n := len(v.comp_tris)
			if n > 0 {
				if rl.IsKeyPressed(
					.PERIOD,
				) {select_comp(&v, &t, v.sel_comp < 0 ? 0 : (v.sel_comp + 1) % n, true)}
				if rl.IsKeyPressed(
					.COMMA,
				) {select_comp(&v, &t, v.sel_comp < 0 ? n - 1 : (v.sel_comp + n - 1) % n, true)}
				if rl.IsKeyPressed(.G) {comp_focus(&v, GHOST_ALPHA)}
				if rl.IsKeyPressed(.H) {comp_focus(&v, 0)}
				if rl.IsKeyPressed(.A) {comp_all(&v)}
			}
		}

		mouse := rl.GetMousePosition()
		panel, _ := comp_layout(&v)
		over_ui :=
			rl.CheckCollisionPointRec(mouse, left_rect()) ||
			rl.CheckCollisionPointRec(mouse, panel) ||
			v.drag_comp >= 0
		update_orbit(&v.orbit, !over_ui, !v.typing)
		cam := to_camera(v.orbit)

		// ---- draw
		rl.BeginDrawing()
		rl.ClearBackground({22, 24, 30, 255})

		rl.BeginMode3D(cam)
		draw_scene(&t, &v, cam)
		rl.EndMode3D()

		draw_labels(&t, &v, cam)
		draw_ui(&t, &v)
		draw_components(&t, &v)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
