package edgebreaker

import ct "../corner_table"
import "core:log"

Vec3 :: ct.Vec3

/********************************* Possible predictors ************************/

/*
Given Predictor Kind create a predictor.
*/
predictor_of :: proc(k: Predictor_Kind) -> Predictor {
	switch k {
	case .NONE:
		return Predictor_None
	case .PARALLELOGRAM:
		return Predictor_Parallelogram
	}
	return Predictor_None
}

Predictor_None :: Predictor {
	kind    = .NONE,
	predict = predict_none,
}

Predictor_Parallelogram :: Predictor {
	kind    = .PARALLELOGRAM,
	predict = predict_parallelogram,
}

/********************** Shared synchronization proc ***************************/

/*
This proc might be used by both encoder&decoder to assert the correctness of
input.

Inputs:
- c: gate corner, in newly discovered triangle
*/
predictor_input :: proc(t: ct.Corner_Table, c: ct.Corner) -> Predictor_Input {
	if c == ct.INVALID_CORNER {
		log.debug("invalid corner for predictor")
		return {}
	}
	gs := ct.pos(t, ct.next(c))
	ge := ct.pos(t, ct.prev(c))
	op_c := ct.op(t, c)
	op: Vec3
	if op_c == ct.INVALID_CORNER {
		log.debug("invalid opposite corner for predictor")
		op = {0, 0, 0}
	} else {
		op = ct.pos(t, op_c)
	}

	return {gs = gs, ge = ge, op = op}
}

/**************************** Structs *****************************************/

Predictor_Kind :: enum u8 {
	NONE,
	PARALLELOGRAM,
}

Predictor_Input :: struct {
	gs, ge: Vec3,
	op:     Vec3,
	// maybe another things if some predictor needs it
}

Predictor_Proc :: #type proc(input: Predictor_Input) -> Vec3

Predictor :: struct {
	kind:    Predictor_Kind,
	predict: Predictor_Proc,
}

/******************************* Implementations ******************************/

/*
Always predict {0,0,0} therefore the correction/delta must be the absolute 
vertex position.
*/
predict_none :: proc(input: Predictor_Input) -> Vec3 {
	return {0, 0, 0}
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
- Vec3: the PREDICTED position of vertex v
*/
predict_parallelogram :: proc(input: Predictor_Input) -> Vec3 {
	return input.gs + input.ge - input.op
}
