# edgebreaker

Implementation of the 
[edgebreaker](https://faculty.cc.gatech.edu/~jarek/papers/EdgeBreaker.pdf)
algorithm in the [odin](https://odin-lang.org/) programming language as seminar
work for [KIV-ZPOS](https://cw.zcu.cz/predmety/kiv/zpos) and KIV-APG in WS2026.

## specs

CLI tool capable of loading
[.obj](https://en.wikipedia.org/wiki/Wavefront_.obj_file) files into in-memory
corner-table representation and compressing them into custom .ebk binary format.
Simultaneously able of loading .ebk files and decompressing them back into .obj
file format.

On top of that, by passing a flag `--trace` it will produce a text file
describing the de/compression step-by-step. Another CLI tool will be able of
visualizing that via raylib.
