# edgebreaker

Implementation of the 
[https://faculty.cc.gatech.edu/~jarek/papers/EdgeBreaker.pdf](edgebreaker)
algorithm in the [https://odin-lang.org/](odin) programming language as seminar
work for [https://cw.zcu.cz/predmety/kiv/zpos](KIV-ZPOS) and KIV-APG in WS2026.

## specs

CLI tool capable of loading
[https://en.wikipedia.org/wiki/Wavefront_.obj_file](.obj) files into in-memory
corner-table representation and compressing them into custom .ebk binary format.
Simultaneously able of loading .ebk files and decompressing them back into .obj
file format.

On top of that, by passing a flag `--trace` it will produce a text file
describing the de/compression step-by-step. Another CLI tool will be able of
visualizing that via raylib.
