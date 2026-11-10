package edgebreaker

import ct "../corner_table"
import "core:log"

Vector3 :: ct.Vec3

/********************************* Possible predictors ************************/

/*
Given Predictor Kind create a predictor.
*/
vertex_codec_of :: proc(k: Vertex_Codec_Kind) -> Vertex_Codec {
	switch k {
	case .RAW:
		return Vertex_Codec_Raw
	case .DELTA_PARALLELOGRAM:
		return Vertex_Codec_Parallelogram
	}
	return Vertex_Codec_Raw
}

Vertex_Codec_Raw :: Vertex_Codec {
	kind        = .RAW,
	encode_tip  = raw_tip,
	decode_tip  = raw_tip,
	encode_loop = raw_loop,
	decode_loop = raw_loop,
}

Vertex_Codec_Parallelogram :: Vertex_Codec {
	kind        = .DELTA_PARALLELOGRAM,
	encode_tip  = parallelogram_encode,
	decode_tip  = parallelogram_decode,
	encode_loop = delta_encode,
	decode_loop = delta_decode,
}

/********************** Shared synchronization proc ***************************/

/*
This proc might be used by both encoder&decoder to assert the correctness of
input.

Inputs:
- c: gate corner, in newly discovered triangle
*/
vertex_codec_context :: proc(t: ct.Corner_Table, c: ct.Corner) -> Tip_Context {
	if c == ct.INVALID_CORNER {
		log.debug("invalid corner for predictor")
		return {}
	}
	gs := ct.pos(t, ct.next(c))
	ge := ct.pos(t, ct.prev(c))
	op_c := ct.op(t, c)
	op: Vector3
	if op_c == ct.INVALID_CORNER {
		log.debug("invalid opposite corner for predictor")
		op = {0, 0, 0}
	} else {
		op = ct.pos(t, op_c)
	}

	return {gate_start = gs, gate_end = ge, opposite = op}
}

/**************************** Structs *****************************************/

Vertex_Codec_Kind :: enum u8 {
	RAW, // absolute positions
	DELTA_PARALLELOGRAM, // delta on loops, parallelogram on tips
}

Tip_Context :: struct {
	gate_start, gate_end: Vector3,
	opposite:             Vector3,
}

Vertex_Codec :: struct {
	kind:        Vertex_Codec_Kind,
	//
	encode_tip:  proc(ctx: Tip_Context, pos: Vector3) -> Vector3,
	decode_tip:  proc(ctx: Tip_Context, residual: Vector3) -> Vector3,
	//
	encode_loop: proc(prev, pos: Vector3) -> Vector3,
	decode_loop: proc(prev, residual: Vector3) -> Vector3,
}

/******************************* Implementations ******************************/

/*
Always predict {0,0,0} therefore the correction/delta must be the absolute 
vertex position.
*/
@(private = "file")
raw_tip :: proc(_: Tip_Context, pos: Vector3) -> Vector3 {
	return pos
}

@(private = "file")
raw_loop :: proc(_, pos: Vector3) -> Vector3 {
	return pos
}


/*
Delta encoding does simply only encode the difference (delta) between two
points.
*/
@(private = "file")
delta_encode :: proc(prev, pos: Vector3) -> Vector3 {
	return pos - prev
}

@(private = "file")
delta_decode :: proc(prev, residual: Vector3) -> Vector3 {
	return prev + residual
}

/*
C operation on any two triangles where gs/ge means gate start/end:
Standard Parallelogram, ie predict: v = gs + ge - o.

   gs--v
  / \ /
 o--ge

Inputs:
- gs, ge: positions of current gate
- op: position of the third vertex in already processed triangle (opposite to
newly found v)

Returns:
- Vector3: the CORRECTION of vertex v
*/
@(private = "file")
parallelogram_encode :: proc(ctx: Tip_Context, pos: Vector3) -> Vector3 {
	return (ctx.gate_start + ctx.gate_end - ctx.opposite) - pos
}

@(private = "file")
parallelogram_decode :: proc(ctx: Tip_Context, residual: Vector3) -> Vector3 {
	return (ctx.gate_start + ctx.gate_end - ctx.opposite) - residual
}
