package edgebreaker

read :: proc(
	filename: string,
	allocator := context.allocator,
	loc := #caller_location,
) -> ^Encoded_Mesh {
	em := new(Encoded_Mesh, allocator, loc)

	return em
}
