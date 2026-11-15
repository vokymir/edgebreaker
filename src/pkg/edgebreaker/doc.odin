/*
Package is capable of encoding and decoding triangle mesh into custom simple
edgebreaker binary format.
*/
package edgebreaker

/*
INFO about structure and assumptions

- vertices: are numbered from 0 to len()-1 in order of appeareance
    1st vtx of component is always gs and is stored as absolute position
    if component has boundary
      encode vtxs on initial border and tip in order gs>...>ge>tip
    else
      encode gs>ge>tip
    on hole
      do the same in order (gate-vertex)>rightmost(v2c(gate))>...

- components: every component stores how long its initial boundary is
  
- topology: 
    handle holes & handles

- triangles: are numbered (using step, where 0=not seen) <1;len()> in order of
    appeareance

- corners: are always t * 3 + k, where k=0 for gate, k=1 for next(gate) and k=2
for next(next(gate))

 */
