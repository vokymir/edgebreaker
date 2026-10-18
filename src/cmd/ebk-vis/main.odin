package visualizer

import rl "vendor:raylib"

Viewer_State :: struct {
	step_index:  int,
	event_count: int,
	playing:     bool,
}

main :: proc() {
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(1100, 720, "EdgeBreaker Visualization Tool")
	defer rl.CloseWindow()

	rl.SetTargetFPS(60)

	for !rl.WindowShouldClose() {
		ctrl_down := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.Q) || (ctrl_down && rl.IsKeyPressed(.W)) {
			break
		}
		rl.ClearBackground(rl.BLACK)
		rl.BeginDrawing()

		rl.DrawText("ahoj", 50, 30, 20, rl.RAYWHITE)

		rl.EndDrawing()
	}
}
