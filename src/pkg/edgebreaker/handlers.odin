package edgebreaker

import "core:fmt"
// here do all standard handlers for edgebreaker

Print_Handler := Encoder_Stream_Handler {
	user_data = nil,
	on_event  = handle_as_print,
}


handle_as_print :: proc(user_data: rawptr, event: Encoder_Event) {
	switch event.op {
	case .C:
		fmt.println("C", event.data.(C_Operation_Data).vertex_delta)
	case .L:
		fmt.println("L")
	case .E:
		fmt.println("E")
	case .R:
		fmt.println("R")
	case .S:
		fmt.println("S")
	case .BOUNDARY_VERTEX:
		fmt.println("Boundary Vertex:", event.data.(B_Operation_Data).vertex_position)
	case .INITIAL_TRIANGLE:
		data := event.data.(Init_Triangle_Operation_Data)
		fmt.println("Initial Triangle:", data.gs, data.ge, data.v)
	}
}
