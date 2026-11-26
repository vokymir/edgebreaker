#!/usr/bin/env python3
"""Print the structure of an STX file. Standalone reference for STX_FORMAT.md (no dependencies).

    python stx_dump.py part.stx

It walks the header and the metadata token stream, lists the geometry buffers, and says
what package obj would do with the file. It is a second, independent implementation of
the format, handy for checking a suspicious file by eye.
"""
import struct
import sys

TOKENS = {1: "NOBITMAP", 2: "BITMAP", 3: "BOUNDINGBOX", 4: "BOUNDINGSPHERE", 5: "REFPLANES", 6: "REFLINES",
          7: "REFPOINTS", 8: "STLDATA", 9: "XMLDATA", 10: "XDATA", 11: "XPROGRESSIVEDATA", 12: "DEFAULTCOLOR",
          13: "OBJECT_ID", 14: "OBJECT_TYPE", 15: "OBJECT_VERSION", 16: "OBJECT_VARIANT", 17: "DEFAULTVIEW",
          18: "BUFFERDATA", 19: "VAULT_EXTENSION", 20: "TEXTURE", 21: "MATERIAL", 22: "NAMED_SURFACES",
          23: "TEXTURE_FILENAME", 24: "USER_DATA_DIRTY"}
TEXT = {13, 14, 15, 16, 19}                       # i32 length + that many ASCII bytes
SIZED = {2, 3, 4, 8, 12, 17, 18, 20, 21}          # i32 size + that many bytes


def main(path):
    d = open(path, "rb").read()
    print("%s: %d bytes" % (path, len(d)))
    if len(d) < 20:
        return print("too short for an STX header")
    version, pointer, pointer2 = struct.unpack_from("<iqq", d, 0)
    print("header: version=0x%x  geometry_pointer=%d  second_pointer=%d" % (version, pointer, pointer2))

    # ---- metadata token stream (informational only: the converter never needs it)
    pos = 20
    while pos + 4 <= len(d):
        tok, = struct.unpack_from("<i", d, pos)
        name = TOKENS.get(tok)
        if name is None:
            print("  @%-6d unknown token %d -> stop (this is not a normal STX stream)" % (pos, tok))
            break
        start, pos = pos, pos + 4
        if tok == 1:                                # NOBITMAP has no payload
            print("  @%-6d %s" % (start, name)); continue
        if tok in TEXT or tok in SIZED:
            size, = struct.unpack_from("<i", d, pos); pos += 4
            shown = d[pos:pos + size].decode("latin-1") if tok in TEXT else "%d bytes" % size
            print("  @%-6d %-16s %s" % (start, name, shown)); pos += size
        else:
            print("  @%-6d %s (payload format not handled here)" % (start, name)); break
    print("  token stream ends at byte %d (file size %d)" % (pos, len(d)))

    # ---- geometry, exactly the way package obj reads it
    if pointer == 0:
        return print("verdict: geometry_pointer is 0 -> no 3D geometry in this file (No_Geometry)")
    if not 0 < pointer < len(d):
        return print("verdict: geometry_pointer is outside the file -> not an STX / corrupt (Bad_Header)")
    token, block_size, count = struct.unpack_from("<iii", d, pointer)
    if token != 18:
        return print("verdict: no BUFFERDATA token at the pointer (No_Buffer_Data)")
    print("geometry block @%d: block_size=%d, %d buffer(s)" % (pointer, block_size, count))
    pos, chosen = pointer + 12, None
    for i in range(count):
        byte_size, level, nv = struct.unpack_from("<ifi", d, pos)
        vo = pos + 12
        nf, = struct.unpack_from("<i", d, vo + 12 * nv)
        narrow = d[vo + 12 * nv + 4] != 0
        io = vo + 12 * nv + 5
        end = io + nf * 3 * (2 if narrow else 4)
        print("  buffer %d @%d: byte_size=%d level=%g  %d vertices  %d triangles  %d-bit indices  (ends @%d)"
              % (i, pos, byte_size, level, nv, nf, 16 if narrow else 32, end))
        if level == 1.0:
            chosen = (vo, nv, io, nf, narrow)         # last buffer with level 1.0 wins
        pos = end
    if chosen is None:
        return print("verdict: no buffer has level 1.0 (No_Matching_Buffer)")
    vo, nv, io, nf, narrow = chosen
    verts = [struct.unpack_from("<3f", d, vo + 12 * i) for i in range(nv)]
    tris = [struct.unpack_from("<3H" if narrow else "<3I", d, io + (6 if narrow else 12) * i) for i in range(nf)]
    unique = len(set(verts))
    print("verdict: converts. level-1.0 buffer: %d stored vertices -> %d distinct positions after welding, %d triangles"
          % (nv, unique, nf))


main(sys.argv[1])
