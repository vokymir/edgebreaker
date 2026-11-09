# DECODER

- add stack of possible gates & similar helpers as in encoder to
  push/pop_unvisited
- remove the assumption of first is C
- add checks for border (in topology, probably use soa_zip)
- using new_vertex_id generate it for each border & hole
- add geometry pass which handles that
- after each step, check for zipping in topology - maybe "index it" by arrive
  corner, so it is then O(1) lookup

