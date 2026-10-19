package visualizer

import eb "../../pkg/edgebreaker"
import rl "vendor:raylib"

// Node in the active boundary ring
Boundary_Node :: struct {
	pos:  rl.Vector3,
	prev: int, // Index of counter-clockwise neighbor
	next: int, // Index of clockwise neighbor
}

create_vis_handler :: proc(vis: ^Vis) -> eb.Encoder_Stream_Handler {
	return {user_data = rawptr(vis), on_event = handle_as_visualizer}
}

handle_as_visualizer :: proc(user_data: rawptr, event: eb.Encoder_Event) {
	vis := cast(^Vis)user_data

	switch event.op {
	case .INITIAL_TRIANGLE:
		data := event.data.(eb.Init_Triangle_Data)
		append(&vis.steps, Step{.INIT, +1, +3})

		// 1. Append solid triangle
		append(&vis.vertices, data.gs, data.ge, data.v)
		append(&vis.triangle_colors, op_to_color(.INIT))

		// 2. Initialize circular boundary loop (v0 -> v1 -> v2)
		clear(&vis.boundary_nodes)
		append(
			&vis.boundary_nodes,
			Boundary_Node{pos = data.gs, prev = 2, next = 1}, // Node 0 (v0)
			Boundary_Node{pos = data.ge, prev = 0, next = 2}, // Node 1 (v1)
			Boundary_Node{pos = data.v, prev = 1, next = 0}, // Node 2 (v2)
		)

		// Set initial active gate: edge (v1, v2)
		vis.gate_v1 = 1
		vis.gate_v2 = 2

	case .C:
		data := event.data.(eb.C_Data)
		append(&vis.steps, Step{.C, +1, +1})

		v_new_pos := data.vertex_delta
		v_new_idx := len(vis.boundary_nodes)

		g1 := vis.gate_v1
		g2 := vis.gate_v2

		// Triangle: (gate_v1, v_new, gate_v2)
		append(&vis.vertices, vis.boundary_nodes[g1].pos, v_new_pos, vis.boundary_nodes[g2].pos)
		append(&vis.triangle_colors, op_to_color(.C))

		// Insert new node between gate_v1 and gate_v2 in the ring
		append(&vis.boundary_nodes, Boundary_Node{pos = v_new_pos, prev = g1, next = g2})

		vis.boundary_nodes[g1].next = v_new_idx
		vis.boundary_nodes[g2].prev = v_new_idx

		// Update gate to (v_new, gate_v2)
		vis.gate_v1 = v_new_idx

	case .R:
		append(&vis.steps, Step{.R, +1, +0})

		g1 := vis.gate_v1
		g2 := vis.gate_v2

		// Opposite vertex is to the RIGHT of gate_v2 in the ring
		v_opp := vis.boundary_nodes[g2].next

		// Triangle: (gate_v1, v_opp, gate_v2)
		append(
			&vis.vertices,
			vis.boundary_nodes[g1].pos,
			vis.boundary_nodes[v_opp].pos,
			vis.boundary_nodes[g2].pos,
		)
		append(&vis.triangle_colors, op_to_color(.R))

		// Remove gate_v2 from boundary loop
		vis.boundary_nodes[g1].next = v_opp
		vis.boundary_nodes[v_opp].prev = g1

		// Advance gate to (gate_v1, v_opp)
		vis.gate_v2 = v_opp

	case .L:
		append(&vis.steps, Step{.L, +1, +0})

		g1 := vis.gate_v1
		g2 := vis.gate_v2

		// Opposite vertex is to the LEFT of gate_v1 in the ring
		v_opp := vis.boundary_nodes[g1].prev

		// Triangle: (gate_v1, gate_v2, v_opp)
		append(
			&vis.vertices,
			vis.boundary_nodes[g1].pos,
			vis.boundary_nodes[g2].pos,
			vis.boundary_nodes[v_opp].pos,
		)
		append(&vis.triangle_colors, op_to_color(.L))

		// Remove gate_v1 from boundary loop
		vis.boundary_nodes[g2].prev = v_opp
		vis.boundary_nodes[v_opp].next = g2

		// Advance gate to (v_opp, gate_v2)
		vis.gate_v1 = v_opp

	case .E:
		append(&vis.steps, Step{.E, +1, +0})

		g1 := vis.gate_v1
		g2 := vis.gate_v2

		// Closes the remaining 3-vertex hole
		v_opp := vis.boundary_nodes[g1].prev

		append(
			&vis.vertices,
			vis.boundary_nodes[g1].pos,
			vis.boundary_nodes[v_opp].pos,
			vis.boundary_nodes[g2].pos,
		)
		append(&vis.triangle_colors, op_to_color(.E))

	case .S:
		append(&vis.steps, Step{.S, +1, +0})
	// Split operation: pushes offset boundary state onto a recursion stack

	case .BOUNDARY_VERTEX:
		append(&vis.steps, Step{.BOUNDARY, +0, +1})
	}
}
