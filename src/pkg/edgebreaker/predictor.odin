package edgebreaker

import "../corner_table"

Vec3 :: corner_table.Vec3

/********************************* POSSIBLE PREDICTORS ************************/

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

/*
C operaion on any two triangles where gs/ge means gate start/end:

   gs--n
  / \ /
 o--ge

Inputs:
- gs, ge: positions of current gate
- o: position of the third vertex in already processed triangle (opposite to
newly found v)

Returns:
- Vec3: the PREDICTED position of vertex v
*/
Predictor_Proc :: #type proc(gs, ge, o: Vec3) -> Vec3

Predictor :: struct {
	kind:    Predictor_Kind,
	predict: Predictor_Proc,
}

/******************************* IMPLEMENTATIONS ******************************/

/*
Always predict {0,0,0} therefore the correction/delta must be the absolute 
vertex position.
*/
predict_none :: proc(gs, ge, o: Vec3) -> Vec3 {
	return {0, 0, 0}
}

/*
Standard Parallelogram, ie predict gs + ge - o.
*/
predict_parallelogram :: proc(gs, ge, o: Vec3) -> Vec3 {
	return gs + ge - o
}
