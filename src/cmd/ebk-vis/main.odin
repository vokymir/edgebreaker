package visualizer

import "core:time"
import rl "vendor:raylib"

Window :: struct {
	name:          cstring,
	width:         i32,
	height:        i32,
	fps:           i32,
	control_flags: rl.ConfigFlags,
}

Page :: enum {
	LOAD,
	VIS,
}

App :: struct {
	page:          Page,
	filename:      cstring,
	//
	error_message: cstring,
	error_time:    time.Time,
}

main :: proc() {
	window := Window{"Edgebreaker Visualizer", 1024, 720, 60, rl.ConfigFlags{.WINDOW_RESIZABLE}}
	app := App{.LOAD, nil, nil, time.now()}

	rl.InitWindow(window.width, window.height, window.name)
	rl.SetWindowState(window.control_flags)
	rl.SetTargetFPS(window.fps)
	defer rl.CloseWindow()

	for !rl.WindowShouldClose() {

		if rl.IsWindowResized() {
			window.width = rl.GetScreenWidth()
			window.height = rl.GetScreenHeight()
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)

		switch app.page {
		case .LOAD:
			draw_load_layout(&app, window)
		case .VIS:
			draw_vis_layout(app, window)
		}

		rl.EndDrawing()
	}
}

draw_load_layout :: proc(app: ^App, win: Window) {
	// Header
	rl.GuiLabel({40, 30, 500, 40}, "EdgeBreaker Visualizer")
	rl.GuiLabel({40, 90, 500, 30}, "Load your mesh")

	// Main panel
	rl.GuiPanel({40, 135, 600, 250}, "Mesh input")

	rl.GuiLabel({65, 180, 540, 30}, "Drag and drop an OBJ file into the window.")

	if app.filename != nil {
		rl.GuiLabel({65, 230, 540, 30}, app.filename)
	}

	if rl.GuiButton({65, 290, 180, 40}, "Use example mesh") {
		app.filename = "../ebk/tetrahedron.obj"
		app.page = .VIS
	}

	if rl.GuiButton({65, 340, 180, 40}, "Continue") {
		if app.filename != nil {
			app.page = .VIS
			app.error_message = nil
		} else {
			app.error_message = "Uuuuh, no file selected..."
			app.error_time = time.now()
		}
	}

	// error message
	if app.error_message != nil {
		elapsed := time.since(app.error_time)

		if elapsed < 3 * time.Second {
			rl.DrawText(app.error_message, 65, 390, 16, rl.BLUE)
		} else {
			app.error_message = nil
		}
	}
}

draw_vis_layout :: proc(app: App, win: Window) {}
