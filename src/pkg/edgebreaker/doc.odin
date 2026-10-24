/*
Package is capable of encoding and decoding triangle mesh into custom simple
edgebreaker binary format.
*/
package edgebreaker

/*
INFO about structure and assumptions

- vertices: are numbered from 0 to len()-1 in order of appeareance
  if component is closed, first 3 vertices (1st triangle) are stored as absolute
positions in order gs,ge,v
  if component has boundary, first are encoded vertices on initial border in
order ge>...>gs>v as absolute positions
  on hole encounter, all vertices are stored in order (gate-vertex)>right>... as
absolute positions

- topology: 
  on initial boundary a topology entry with #verts is saved as (-1,-1,#verts)
  on every hole a topology entry with #verts is saved as (s,a,#verts)

- triangles: are numbered <1;len()> in order of appeareance

- corners: are always t * 3 + k, where k=0 for gate, k=1 for next(gate) and k=2
for next(next(gate))

 */
