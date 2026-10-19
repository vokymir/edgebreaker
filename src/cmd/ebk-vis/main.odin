package visualizer

import "core:time"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

Window :: struct {
	name:          cstring,
	width:         i32,
	height:        i32,
	fps:           i32,
	control_flags: rl.ConfigFlags,
}

Vis :: struct {
	tick_rate: time.Duration,
	last_tick: time.Time,
	autoplay:  bool,
	step:      int,
	steps:     []Step,
}

main :: proc() {
	window := Window{"Edgebreaker Visualizer", 1024, 720, 60, rl.ConfigFlags{.WINDOW_RESIZABLE}}

	rl.InitWindow(window.width, window.height, window.name)
	rl.SetWindowState(window.control_flags)
	rl.SetTargetFPS(window.fps)
	defer rl.CloseWindow()


	vis := Vis {
		tick_rate = 300 * time.Millisecond,
		last_tick = time.now(),
		autoplay  = false,
		step      = 0,
		steps     = {
			{op = .INIT, tri_delta = 1, vert_delta = 3},
			{op = .C, tri_delta = 1, vert_delta = 1},
			{op = .R, tri_delta = 1, vert_delta = 0},
			{op = .L, tri_delta = 1, vert_delta = 0},
			{op = .E, tri_delta = 1, vert_delta = 0},
		},
	}
	raw_positions := [][3]f32 {
		// Tri 0 (Init)
		{-1.0, 0.0, -1.0},
		{1.0, 0.0, -1.0},
		{0.0, 1.0, 0.0},
		// Tri 1 (C)
		{1.0, 0.0, -1.0},
		{0.0, 0.0, 1.0},
		{0.0, 1.0, 0.0},
		// Tri 2 (R)
		{0.0, 0.0, 1.0},
		{-1.0, 0.0, -1.0},
		{0.0, 1.0, 0.0},
		// Tri 3 (L)
		{-1.0, 0.0, -1.0},
		{1.0, 0.0, -1.0},
		{0.0, 0.0, 1.0},
		// Tri 4 (E)
		{-1.0, 0.0, -1.0},
		{0.0, -1.0, 0.0},
		{1.0, 0.0, -1.0},
	}
	total_triangles := len(vis.steps)
	total_vertices := total_triangles * 3

	// Flatten coordinates and build initial per-vertex color array
	vertices := make([]f32, total_vertices * 3)
	colors := make([]rl.Color, total_vertices)
	indices := make([]u16, total_vertices)
	defer delete(vertices)
	defer delete(colors)
	defer delete(indices)

	for i in 0 ..< total_vertices {
		vertices[i * 3 + 0] = raw_positions[i][0]
		vertices[i * 3 + 1] = raw_positions[i][1]
		vertices[i * 3 + 2] = raw_positions[i][2]

		indices[i] = u16(i)

		// Map triangle index to step operation color
		tri_idx := i / 3
		colors[i] = op_to_color(vis.steps[tri_idx].op)
	}

	// 2. Build Raylib Mesh
	mesh: rl.Mesh
	mesh.vertexCount = i32(total_vertices)
	mesh.triangleCount = i32(total_triangles)
	mesh.vertices = raw_data(vertices)
	mesh.indices = raw_data(indices)
	mesh.colors = cast(^u8)raw_data(colors)

	// Dynamic = true allows streaming updates to GPU VBOs
	rl.UploadMesh(&mesh, true)
	defer rl.UnloadMesh(mesh)

	material := rl.LoadMaterialDefault()
	defer rl.UnloadMaterial(material)

	camera := rl.Camera3D {
		position   = {10, 10, 10}, // Camera position
		//target = {0, 0, 0},      // Camera looking at point
		up         = {0, 1, 0}, // Camera up vector (rotation towards target)
		fovy       = 45, // Camera field-of-view Y
		projection = .PERSPECTIVE, // Camera projection type
	}

	cube_pos := rl.Vector3{0, 0, 0}

	rl.DisableCursor()


	for !rl.WindowShouldClose() {

		rl.UpdateCamera(&camera, .FREE)

		if rl.IsWindowResized() {
			window.width = rl.GetScreenWidth()
			window.height = rl.GetScreenHeight()
		}

		// process user input

		if rl.IsKeyPressed(.Z) {camera.target = {0, 0, 0}}
		if rl.IsKeyPressed(.RIGHT) && vis.step < len(vis.steps) - 1 {
			vis.step += 1
		}
		if rl.IsKeyPressed(.LEFT) && vis.step > 0 {
			vis.step -= 1
		}

		// update world state

		// Calculate cumulative vertices and triangles revealed up to current_step
		active_tris: i32 = 0
		active_verts: i32 = 0
		for i in 0 ..= vis.step {
			active_tris += vis.steps[i].tri_delta
			active_verts += vis.steps[i].vert_delta
		}

		// Update Raylib rendering bounds
		mesh.triangleCount = active_tris
		mesh.vertexCount = active_tris * 3

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		rl.BeginMode3D(camera)

		rlgl.DisableBackfaceCulling()
		rl.DrawMesh(mesh, material, rl.Matrix(1))

		// Wireframe overlay for edge clarity
		rl.DrawMesh(mesh, material, rl.Matrix(1))

		rlgl.EnableBackfaceCulling()

		// rl.DrawCube(cube_pos, 2, 2, 2, rl.RED)
		// rl.DrawCubeWires(cube_pos, 2, 2, 2, rl.MAROON)
		//
		// rl.DrawGrid(10, 1)


		rl.EndMode3D()
		// Step HUD
		step_info := vis.steps[vis.step]
		rl.DrawText(
			rl.TextFormat(
				"Step %d/%d | Op: %v | Total Verts Known: %d | Tris: %d",
				vis.step + 1,
				len(vis.steps),
				step_info.op,
				active_verts,
				active_tris,
			),
			20,
			20,
			20,
			rl.DARKGRAY,
		)

		rl.DrawFPS(window.width - 50, 10)

		rl.EndDrawing()
	}
}
