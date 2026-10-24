package edgebreaker
/* Public API of compression. */

Vector3 :: [3]f32

/***************************** Structs ****************************************/
/* NOTE: another structs are in related compression files, notably in
encoder_ct.odin

Those structs are implementation-dependant, while these here are not.
*/


/*
What is the operation done (= symbol emitted) on triangle?
*/
Operation :: enum {
	// finds new vertex
	C, // create
	// traverse the spanning tree
	L, // left
	R, // right
	// parantheses
	S, // split
	E, // end
}

/*
Marks vertices as the algorithm goes through the mesh.
*/
Mark :: enum {
	NOT_VISITED,
	VISITED,
	HOLE,
}

/***************************** Compression ************************************/

compress :: proc {
	compress_ct,
}
