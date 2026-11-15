#+private
package edgebreaker

import ct "../corner_table"

/*
Common logic for encoder and decoders.
Another part might be found in public.odin
*/

/***************************** TYPES ******************************************/

Gate :: distinct int

/********************************** PROCEDURES ********************************/

/*
Decide which clers symbol is this situation.

Inputs:
- tip_is_new: tip vertex was not previously reached AND is not on hole
- right/left_done: r/l triangle already processed or doesn't exist (border)
*/
clers_symbol :: proc(tip_is_new, right_done, left_done: bool) -> Operation {
	switch {
	case tip_is_new:
		return .C
	case right_done && left_done:
		return .E
	case right_done:
		return .R
	case left_done:
		return .L
	case:
		return .S
	}
}

/*
Return the corner of triangle given by its tip corner and desired edge side.
*/
side_corner :: #force_inline proc(tip: ct.Corner, side: Side) -> ct.Corner {
	if side == .RIGHT {return ct.next(tip)} else {return ct.prev(tip)}
}
