# box

uses more than 6 symbols??? vertices ok

# hole

triangle visited twice

# initial S

3    5
| \ / |
|1 1 2|
| /0\ |
2-----0

vertices and faces as loaded (faces has number also)

start with L not S. assumption: 1st gate is corner 1, but it is 2 - so the L
makes sense, but the gate selection does not

# multiple meshes = rect + tetrahedron

in rectangle it selects invalid gate so it just ends with straigt "E"
tetrahedron is ok

fails on rectangle

# non-orientable

problem - cannot find boundary correctly, then tri visited 2x (maybe problem
because of rectangle though)

# paper

ok

# rectangle

invalid gate selection

# tetrahedron

ok


