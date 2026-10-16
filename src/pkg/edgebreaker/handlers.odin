package edgebreaker

import "core:fmt"

/*
Standard Stream Handlers for encoding.
*/

/********************************* Take-and-use *******************************/

/*
Print everything straight to console using core:fmt.
*/
Print_Handler := Encoder_Stream_Handler {
	user_data = nil,
	on_event  = handle_as_print,
}

emit_step :: proc(state: ^Encoder_State, event: Encoder_Event) {
	if state.handler.on_event != nil {
		state.handler.on_event(state.handler.user_data, event)
	}
}

/********************************* Definitions ********************************/

/*
Defines how to actually encode/store symbols & vertices emitted by edgebreaker.
*/
Encoder_Stream_Handler :: struct {
	// may be nothing, or eg. queue - is passed to every on_event() call
	user_data: rawptr,
	// what to do with each symbol
	on_event:  Encoder_Event_Proc,
}

/*
What to do with any symbol emited by edgebreaker.
*/
Encoder_Event_Proc :: #type proc(user_data: rawptr, event: Encoder_Event)

/*
Represents one step in the edgebreaker algorithm
*/
Encoder_Event :: struct {
	op:   Operation,
	data: Operation_Data,
}

// initializing edgebreaker phase on mesh with boundary with boundary vertices
Boundary_Data :: struct {
	vertex_position: Vec3,
}

Init_Triangle_Data :: struct {
	gs, ge, v: Vec3,
}

// standard CLERS operations - only C must have new vertex delta based on
// predictor.

C_Data :: struct {
	vertex_delta: Vec3,
}

L_Data :: struct {}
R_Data :: struct {}

S_Data :: struct {}
E_Data :: struct {}

Operation_Data :: union {
	C_Data,
	L_Data,
	E_Data,
	R_Data,
	S_Data,
	Boundary_Data,
	Init_Triangle_Data,
}


/******************************* Implementations ******************************/

handle_as_print :: proc(user_data: rawptr, event: Encoder_Event) {
	switch event.op {
	case .C:
		fmt.println("C", event.data.(C_Data).vertex_delta)
	case .L:
		fmt.println("L")
	case .E:
		fmt.println("E")
	case .R:
		fmt.println("R")
	case .S:
		fmt.println("S")
	case .BOUNDARY_VERTEX:
		fmt.println("Boundary Vertex:", event.data.(Boundary_Data).vertex_position)
	case .INITIAL_TRIANGLE:
		data := event.data.(Init_Triangle_Data)
		fmt.println("Initial Triangle:", data.gs, data.ge, data.v)
	}
}
