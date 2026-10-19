package visualizer

import rl "vendor:raylib"

Operation :: enum {
	INIT,
	BOUNDARY,
	C,
	L,
	E,
	R,
	S,
}

Step :: struct {
	op:         Operation,
	tri_delta:  i32,
	vert_delta: i32,
}

op_to_color :: proc(op: Operation) -> rl.Color {
	switch op {
	case .INIT:
		return rl.LIGHTGRAY
	case .C:
		return rl.RED
	case .L:
		return rl.GREEN
	case .E:
		return rl.GOLD
	case .R:
		return rl.BLUE
	case .S:
		return rl.PURPLE
	case .BOUNDARY:
		fallthrough // the color is irrelevant...
	case:
		return rl.WHITE
	}
}
