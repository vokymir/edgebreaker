package edgebreaker

import "../corner_table"

Vec3 :: corner_table.Vec3

/********************************* POSSIBLE PREDICTORS ************************/

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

/**************************** STRUCTS *****************************************/

Predictor_Kind :: enum {
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

/******************************* IMPLEMENTATIONS ******************************/

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
