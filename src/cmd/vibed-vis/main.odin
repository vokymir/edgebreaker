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
// Keys:  arrows = orbit | R = reset view | 1/2/3 = demo mesh
//        F faces | E edges | P vertex points | V vertex ids | T triangle ids
//        C corner ids | X vertex positions | N normal arrows | W winding arrows
//
// To view your own mesh: fill `t` (a Corner_Table) in main() instead of
// calling load_demo(). Everything below only reads the table.
package main

import ct "../../pkg/corner_table"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

Vec3 :: ct.Vec3

FONT :: 16
FOVY :: f32(45)
FACE_SHRINK :: f32(0.94) // faces are drawn a bit smaller so edges stay visible
WIND_SCALE :: f32(0.5) // size of the inner winding loop relative to the triangle

FRONT_COLOR :: rl.Color{70, 120, 190, 255} // seen from the CCW side
BACK_COLOR :: rl.Color{190, 70, 90, 255} // seen from the CW side
WINDING_COLOR :: rl.Color{225, 130, 255, 255}

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

DEMO_NAME := [?]string{"grid (open, has boundary)", "octahedron (closed)", "tetrahedron (closed)"}

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

load_demo :: proc(t: ^ct.Corner_Table, which: int) {
	clear(&t.pos)
	clear(&t.c2v)
	clear(&t.op)
	clear(&t.v2c)

	verts := make([dynamic]Vec3, context.temp_allocator)
	tris := make([dynamic]int, context.temp_allocator)

	switch which {
	case 0:
		// 3 x 2 quads, each split in two triangles, in the XY plane
		NX, NY :: 3, 2
		for j in 0 ..= NY {
			for i in 0 ..= NX {
				append(&verts, Vec3{f32(i) - NX / 2.0, f32(j) - NY / 2.0, 0})
			}
		}
		for j in 0 ..< NY {
			for i in 0 ..< NX {
				a := j * (NX + 1) + i
				b := a + 1
				d := a + (NX + 1)
				c := d + 1
				append(&tris, a, b, c, a, c, d)
			}
		}
	case 1:
		append(
			&verts,
			Vec3{1, 0, 0},
			Vec3{-1, 0, 0},
			Vec3{0, 1, 0},
			Vec3{0, -1, 0},
			Vec3{0, 0, 1},
			Vec3{0, 0, -1},
		)
		for sx in 0 ..< 2 {
			for sy in 0 ..< 2 {
				for sz in 0 ..< 2 {
					a, b, c := sx, 2 + sy, 4 + sz
					if (sx + sy + sz) % 2 == 1 {b, c = c, b} 	// keep CCW seen from outside
					append(&tris, a, b, c)
				}
			}
		}
	case 2:
		append(&verts, Vec3{1, 1, 1}, Vec3{1, -1, -1}, Vec3{-1, 1, -1}, Vec3{-1, -1, 1})
		append(&tris, 0, 1, 2, 0, 2, 3, 0, 3, 1, 1, 3, 2)
	}

	build(t, verts[:], tris[:])
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

// Orbit that frames the whole mesh.
frame :: proc(t: ^ct.Corner_Table) -> Orbit {
	o := Orbit {
		yaw   = 0.5,
		pitch = 0.45,
		dist  = 6,
	}
	if len(t.pos) == 0 {return o}

	lo, hi := t.pos[0], t.pos[0]
	for p in t.pos {
		for i in 0 ..< 3 {
			lo[i] = min(lo[i], p[i])
			hi[i] = max(hi[i], p[i])
		}
	}
	o.target = (lo + hi) / 2
	radius := max(linalg.length(hi - lo) / 2, 0.001)
	o.dist = 1.3 * radius / math.tan(FOVY * math.RAD_PER_DEG / 2)
	return o
}

update_orbit :: proc(o: ^Orbit, ui_blocked: bool) {
	if !ui_blocked {
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

	dt := rl.GetFrameTime()
	if rl.IsKeyDown(.LEFT) {o.yaw -= 1.5 * dt}
	if rl.IsKeyDown(.RIGHT) {o.yaw += 1.5 * dt}
	if rl.IsKeyDown(.UP) {o.pitch += 1.5 * dt}
	if rl.IsKeyDown(.DOWN) {o.pitch -= 1.5 * dt}

	o.pitch = clamp(o.pitch, -1.55, 1.55)
	o.dist = max(o.dist, 0.01)
}

/****************************** Drawing helpers *******************************/

shade :: proc(c: rl.Color, k: f32) -> rl.Color {
	return {u8(f32(c.r) * k), u8(f32(c.g) * k), u8(f32(c.b) * k), 255}
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

// world -> screen; ok is false if the point is behind the camera
project :: proc(p: Vec3, cam: rl.Camera3D) -> (s: rl.Vector2, ok: bool) {
	fwd := linalg.normalize0(cam.target - cam.position)
	if linalg.dot(p - cam.position, fwd) < 0.01 {return}
	return rl.GetWorldToScreen(p, cam), true
}

// text with a dark backing box so it is readable over faces
label :: proc(text: cstring, x, y: i32, color: rl.Color, alpha: f32 = 1, centered := false) {
	x := x
	w := rl.MeasureText(text, FONT)
	if centered {x -= w / 2}
	rl.DrawRectangle(x - 2, y - 1, w + 4, FONT + 2, rl.Fade(rl.BLACK, 0.6 * alpha))
	rl.DrawText(text, x, y, FONT, rl.Fade(color, alpha))
}

/****************************** Scene (3D) ************************************/

View :: struct {
	opts:  [Opt]bool,
	orbit: Orbit,
	demo:  int,
}

draw_scene :: proc(t: ^ct.Corner_Table, v: ^View, cam: rl.Camera3D) {
	opts := v.opts

	for ti in 0 ..< len(t.c2v) / 3 {
		a, b, c := tri_pts(t, ti)
		cen := (a + b + c) / 3
		n := linalg.normalize0(linalg.cross(b - a, c - a))
		avg_edge := (linalg.length(b - a) + linalg.length(c - b) + linalg.length(a - c)) / 3

		if opts[.Faces] {
			// headlight shading; with back-face culling each side gets its own colour
			facing := abs(linalg.dot(n, linalg.normalize0(cam.position - cen)))
			k := min(0.45 + 0.55 * facing, 1)
			a2 := cen + (a - cen) * FACE_SHRINK
			b2 := cen + (b - cen) * FACE_SHRINK
			c2 := cen + (c - cen) * FACE_SHRINK
			rl.DrawTriangle3D(a2, b2, c2, shade(FRONT_COLOR, k))
			rl.DrawTriangle3D(a2, c2, b2, shade(BACK_COLOR, k))
		}

		if opts[.Normals] {
			arrow(cen, cen + n * (avg_edge * 0.5), rl.GREEN)
		}

		if opts[.Winding] {
			// small CCW loop inside the triangle: corner c -> next(c)
			for k in 0 ..< 3 {
				corner := ct.Corner(3 * ti + k)
				p0 := cen + (ct.pos(t^, corner) - cen) * WIND_SCALE
				p1 := cen + (ct.pos(t^, ct.next(corner)) - cen) * WIND_SCALE
				arrow(p0 + (p1 - p0) * 0.15, p0 + (p1 - p0) * 0.85, WINDING_COLOR)
			}
		}
	}

	if opts[.Edges] {
		for ci in 0 ..< len(t.c2v) {
			c := ct.Corner(ci)
			opp := ct.op(t^, c)
			if opp >= 0 && opp < c {continue} 	// interior edge: drawn from its other side
			a := ct.pos(t^, ct.next(c))
			b := ct.pos(t^, ct.prev(c))
			rl.DrawLine3D(a, b, opp < 0 ? rl.RED : rl.LIGHTGRAY) // red = boundary
		}
	}

	if opts[.Points] {
		radius := v.orbit.dist * 0.006 // roughly constant size on screen
		for p in t.pos {
			rl.DrawSphereEx(p, radius, 8, 8, rl.YELLOW)
		}
	}
}

/****************************** Labels (2D overlay) ***************************/

draw_labels :: proc(t: ^ct.Corner_Table, v: ^View, cam: rl.Camera3D) {
	opts := v.opts

	if opts[.Vertex_Ids] || opts[.Positions] {
		for p, i in t.pos {
			s := project(p, cam) or_continue
			x, y := i32(s.x) + 8, i32(s.y)
			if opts[.Vertex_Ids] {
				label(fmt.ctprintf("v%d", i), x, y - FONT - 6, rl.YELLOW)
			}
			if opts[.Positions] {
				label(fmt.ctprintf("(%.2f, %.2f, %.2f)", p.x, p.y, p.z), x, y + 6, rl.LIGHTGRAY)
			}
		}
	}

	if opts[.Tri_Ids] || opts[.Corner_Ids] {
		for ti in 0 ..< len(t.c2v) / 3 {
			a, b, c := tri_pts(t, ti)
			cen := (a + b + c) / 3
			n := linalg.cross(b - a, c - a)
			// labels of triangles facing away from the camera are dimmed
			alpha: f32 = linalg.dot(n, cam.position - cen) > 0 ? 1 : 0.35

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
}

/****************************** UI ********************************************/

UI_X, UI_Y, UI_W, UI_ROW :: 10, 10, 250, 22

ui_rect :: proc() -> rl.Rectangle {
	return {UI_X, UI_Y, UI_W, f32(UI_ROW * len(Opt) + 20)}
}

draw_ui :: proc(t: ^ct.Corner_Table, v: ^View) {
	r := ui_rect()
	rl.DrawRectangleRec(r, rl.Fade(rl.BLACK, 0.55))

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

	y := i32(r.y + r.height) + 10
	rl.DrawText(fmt.ctprintf("mesh [1-3]: %s", DEMO_NAME[v.demo]), UI_X, y, FONT, rl.RAYWHITE)
	rl.DrawText(
		fmt.ctprintf("V %d   T %d   C %d", len(t.pos), len(t.c2v) / 3, len(t.c2v)),
		UI_X,
		y + 22,
		FONT,
		rl.LIGHTGRAY,
	)

	h := rl.GetScreenHeight()
	rl.DrawText(
		"faces: blue = front (CCW side), red = back   |   red edge = boundary (op < 0)",
		10,
		h - 48,
		FONT,
		rl.GRAY,
	)
	rl.DrawText(
		"LMB orbit | RMB / Shift+LMB pan | wheel zoom | arrows orbit | R reset view | Esc quit",
		10,
		h - 26,
		FONT,
		rl.GRAY,
	)
}

/****************************** Main ******************************************/

main :: proc() {
	rl.SetConfigFlags({.MSAA_4X_HINT, .WINDOW_RESIZABLE})
	rl.InitWindow(1280, 800, "corner table viewer")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	t: ct.Corner_Table
	ct.init(&t)
	defer ct.destroy(&t)

	v: View
	for opt in Opt {v.opts[opt] = true}
	v.opts[.Positions] = false

	ct.load(&t, "../../../assets/medium/suzanne_od_simona.obj")
	// load_demo(&t, v.demo) // <- replace with your own table
	v.orbit = frame(&t)

	demo_keys := [?]rl.KeyboardKey{.ONE, .TWO, .THREE}

	for !rl.WindowShouldClose() {
		// ---- input
		for opt in Opt {
			if rl.IsKeyPressed(OPT_KEY[opt]) {v.opts[opt] = !v.opts[opt]}
		}
		for key, i in demo_keys {
			if rl.IsKeyPressed(key) {
				v.demo = i
				load_demo(&t, i)
				v.orbit = frame(&t)
			}
		}
		if rl.IsKeyPressed(.R) {v.orbit = frame(&t)}

		over_ui := rl.CheckCollisionPointRec(rl.GetMousePosition(), ui_rect())
		update_orbit(&v.orbit, over_ui)
		cam := to_camera(v.orbit)

		// ---- draw
		rl.BeginDrawing()
		rl.ClearBackground({22, 24, 30, 255})

		rl.BeginMode3D(cam)
		draw_scene(&t, &v, cam)
		rl.EndMode3D()

		draw_labels(&t, &v, cam)
		draw_ui(&t, &v)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}
