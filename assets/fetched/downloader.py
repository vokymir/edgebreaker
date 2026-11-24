#!/usr/bin/env python3
"""
meshkit.py - fetch standard triangle-mesh test sets, report their topology,
             and check whether two meshes are isomorphic.

  python meshkit.py fetch [--out meshes] [--sets stanford,gt,jacobson,crane,synthetic,thingi]
                          [--exclude lucy,thai] [--format obj|ply] [--dry-run] [--force]
                          # meshes whose output file already exists are skipped (use --force to redo)
  python meshkit.py info  a.obj b.ply ...            # V/E/F, components, boundary loops, genus, manifold, orientation
  python meshkit.py iso   a.obj b.obj                # connectivity isomorphism (orientation preserving)
  python meshkit.py iso   a.obj b.obj --geometric    # same positions + same triangles (no vertex-order assumptions)
  python meshkit.py iso   a.obj b.drc.obj --geometric --tol 1e-3   # quantised copy (e.g. Draco): match within tol
  python meshkit.py synth [--out meshes/synthetic]   # tetra, tori, genus-g, Czaszar, long tube, bad meshes ...
  python meshkit.py subdivide in.obj out.obj --levels 2   # 1->4 midpoint subdivision (same topology, 4x faces)

Needs:  python >= 3.9, numpy, scipy.   Optional: thingi10k (pip), networkx (fallback for non-manifold iso).
Exit code of `iso`: 0 = isomorphic, 1 = not isomorphic, 2 = inconclusive (time limit / too big for fallback).
"""
import argparse
import csv
import gzip
import os
import re
import shutil
import socket
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
import zipfile
from urllib.parse import urljoin

import numpy as np

try:
    import scipy.sparse as sp
    from scipy.sparse.csgraph import connected_components
except ImportError:  # pragma: no cover
    sys.exit("meshkit needs numpy and scipy:  pip install numpy scipy")


# =============================================================================
#  Mesh I/O  (OBJ, PLY ascii + binary, OFF; transparent .gz)
# =============================================================================

def _read_bytes(path):
    p = str(path)
    if p.endswith(".gz"):
        with gzip.open(p, "rb") as f:
            return f.read()
    with open(p, "rb") as f:
        return f.read()


def _fan(rows):
    """list of index arrays (any length >=3) -> (m,3) triangles, max polygon size (0 if all triangles)"""
    tris, poly = [], 0
    for r in rows:
        n = len(r)
        if n == 3:
            tris.append(r)
        elif n > 3:
            poly = max(poly, n)
            for k in range(1, n - 1):
                tris.append((r[0], r[k], r[k + 1]))
    return np.array(tris, dtype=np.int64).reshape(-1, 3), poly


def _fan_uniform(a):
    """(m,n) polygon array -> (m*(n-2),3) triangles"""
    n = a.shape[1]
    if n == 3:
        return a
    return np.concatenate([a[:, [0, k, k + 1]] for k in range(1, n - 1)])


def read_obj(path):
    V, F, poly = [], [], 0
    for line in _read_bytes(path).split(b"\n"):
        if line[:2] == b"v ":
            p = line.split()
            V.append((float(p[1]), float(p[2]), float(p[3])))
        elif line[:2] == b"f ":
            n = len(V)
            idx = []
            for t in line.split()[1:]:
                i = int(t.split(b"/")[0])
                idx.append(i - 1 if i > 0 else n + i)
            if len(idx) == 3:
                F.append(idx)
            elif len(idx) > 3:
                poly = max(poly, len(idx))
                for k in range(1, len(idx) - 1):
                    F.append((idx[0], idx[k], idx[k + 1]))
    return (np.array(V, dtype=np.float64).reshape(-1, 3),
            np.array(F, dtype=np.int64).reshape(-1, 3), {"max_poly": poly})


def read_off(path):
    toks = _read_bytes(path).split()
    if toks[0].upper().startswith(b"OFF"):
        toks = toks[1:]
    nv, nf = int(toks[0]), int(toks[1])
    p = 3
    V = np.array(toks[p:p + 3 * nv], dtype=np.float64).reshape(nv, 3)
    p += 3 * nv
    rows = []
    for _ in range(nf):
        n = int(toks[p])
        rows.append(np.array(toks[p + 1:p + 1 + n], dtype=np.int64))
        p += 1 + n
    F, poly = _fan(rows)
    return V, F, {"max_poly": poly}


_PLY_T = {"char": "i1", "int8": "i1", "uchar": "u1", "uint8": "u1", "short": "i2", "int16": "i2",
          "ushort": "u2", "uint16": "u2", "int": "i4", "int32": "i4", "uint": "u4", "uint32": "u4",
          "float": "f4", "float32": "f4", "double": "f8", "float64": "f8"}


def parse_ply(buf):
    m = re.search(rb"end_header\r?\n", buf)
    if not m:
        raise ValueError("not a PLY file (no end_header)")
    fmt, elems = None, []
    for ln in buf[:m.start()].decode("latin1").splitlines():
        t = ln.split()
        if not t:
            continue
        if t[0] == "format":
            fmt = t[1]
        elif t[0] == "element":
            elems.append([t[1], int(t[2]), []])
        elif t[0] == "property":
            if t[1] == "list":
                elems[-1][2].append((t[4], "list", t[2], t[3]))
            else:
                elems[-1][2].append((t[2], t[1], None, None))
    off = m.end()
    if fmt == "ascii":
        V, F, poly = _ply_ascii(buf, off, elems)
    else:
        V, F, poly = _ply_binary(buf, off, elems, "<" if fmt == "binary_little_endian" else ">")
    if V is None or F is None:
        raise ValueError("PLY file has no vertex/face data")
    return V, F, {"max_poly": poly}


def _ply_binary(buf, off, elems, en):
    V = F = None
    poly = 0
    for name, count, props in elems:
        if not any(p[1] == "list" for p in props):
            dt = np.dtype([(p[0], en + _PLY_T[p[1]]) for p in props])
            arr = np.frombuffer(buf, dtype=dt, count=count, offset=off)
            off += count * dt.itemsize
            if name == "vertex":
                V = np.stack([arr["x"], arr["y"], arr["z"]], axis=1)
            continue
        if len(props) == 1 and count > 0:                      # fast path: uniform polygon size
            _, _, ct, it = props[0]
            n = int(np.frombuffer(buf, dtype=en + _PLY_T[ct], count=1, offset=off)[0])
            dt = np.dtype([("n", en + _PLY_T[ct]), ("i", en + _PLY_T[it], (n,))])
            if off + count * dt.itemsize <= len(buf):
                arr = np.frombuffer(buf, dtype=dt, count=count, offset=off)
                if (arr["n"] == n).all():
                    off += count * dt.itemsize
                    if name == "face":
                        F = _fan_uniform(arr["i"].astype(np.int64))
                        poly = n if n > 3 else 0
                    continue
        rows, first = [], True                                  # slow generic path
        for _ in range(count):
            for p in props:
                if p[1] == "list":
                    cdt = np.dtype(en + _PLY_T[p[2]])
                    n = int(np.frombuffer(buf, cdt, 1, off)[0])
                    off += cdt.itemsize
                    idt = np.dtype(en + _PLY_T[p[3]])
                    if first and name == "face":
                        rows.append(np.frombuffer(buf, idt, n, off).astype(np.int64))
                    first = False
                    off += n * idt.itemsize
                else:
                    off += np.dtype(_PLY_T[p[1]]).itemsize
            first = True
        if name == "face":
            F, poly = _fan(rows)
    return V, F, poly


def _ply_ascii(buf, off, elems):
    txt = buf[off:].decode("latin1")
    try:
        arr = np.fromstring(txt, dtype=np.float64, sep=" ")
    except Exception:  # np.fromstring may disappear in future numpy releases
        arr = np.array(txt.split(), dtype=np.float64)
    p, V, F, poly = 0, None, None, 0
    for name, count, props in elems:
        if not any(q[1] == "list" for q in props):
            k = len(props)
            blk = arr[p:p + count * k].reshape(count, k)
            p += count * k
            if name == "vertex":
                nm = [q[0] for q in props]
                V = blk[:, [nm.index("x"), nm.index("y"), nm.index("z")]]
            continue
        if len(props) == 1 and count > 0:
            n = int(arr[p])
            blk = arr[p:p + count * (n + 1)]
            if blk.size == count * (n + 1):
                blk = blk.reshape(count, n + 1)
                if (blk[:, 0] == n).all():
                    p += count * (n + 1)
                    if name == "face":
                        F = _fan_uniform(blk[:, 1:].astype(np.int64))
                        poly = n if n > 3 else 0
                    continue
        rows = []
        for _ in range(count):
            first = True
            for q in props:
                if q[1] == "list":
                    n = int(arr[p])
                    if first and name == "face":
                        rows.append(arr[p + 1:p + 1 + n].astype(np.int64))
                    first = False
                    p += 1 + n
                else:
                    p += 1
        if name == "face":
            F, poly = _fan(rows)
    return V, F, poly


def read_ply(path):
    return parse_ply(_read_bytes(path))


def load_mesh(path):
    """-> V (n,3) float, F (m,3) int64 (polygons fan-triangulated), meta {'max_poly': 0 | n}"""
    p = str(path).lower()
    base = p[:-3] if p.endswith(".gz") else p
    if base.endswith(".obj"):
        return read_obj(path)
    if base.endswith(".ply"):
        return read_ply(path)
    if base.endswith(".off"):
        return read_off(path)
    raise ValueError("unsupported mesh format: " + str(path))


def _vfmt(V):
    return "%.9g" if V.dtype == np.float32 else "%.12g"


def write_obj(path, V, F, comment=None):
    d = os.path.dirname(str(path))
    if d:
        os.makedirs(d, exist_ok=True)
    f3 = "v {0} {0} {0}\n".format(_vfmt(V))
    with open(path, "w", buffering=1 << 20) as f:
        if comment:
            f.write("# " + comment + "\n")
        for i in range(0, len(V), 500000):
            f.write("".join([f3 % tuple(r) for r in V[i:i + 500000].tolist()]))
        F1 = np.asarray(F) + 1
        for i in range(0, len(F1), 500000):
            f.write("".join(["f %d %d %d\n" % tuple(r) for r in F1[i:i + 500000].tolist()]))


def write_ply(path, V, F, comment=None):
    d = os.path.dirname(str(path))
    if d:
        os.makedirs(d, exist_ok=True)
    f3 = "{0} {0} {0}\n".format(_vfmt(V))
    with open(path, "w", buffering=1 << 20) as f:
        f.write("ply\nformat ascii 1.0\n")
        if comment:
            f.write("comment " + comment + "\n")
        f.write("element vertex %d\nproperty float x\nproperty float y\nproperty float z\n" % len(V))
        f.write("element face %d\nproperty list uchar int vertex_indices\nend_header\n" % len(F))
        for i in range(0, len(V), 500000):
            f.write("".join([f3 % tuple(r) for r in V[i:i + 500000].tolist()]))
        for i in range(0, len(F), 500000):
            f.write("".join(["3 %d %d %d\n" % tuple(r) for r in np.asarray(F[i:i + 500000]).tolist()]))


def save_mesh(path_noext, V, F, fmt="obj", comment=None):
    path = "%s.%s" % (path_noext, fmt)
    (write_obj if fmt == "obj" else write_ply)(path, V, F, comment)
    return path


def weld(V, F):
    """merge vertices with bit-identical coordinates (first occurrence keeps its index order)"""
    _, first, inv = np.unique(V, axis=0, return_index=True, return_inverse=True)
    inv = np.asarray(inv).reshape(-1)
    order = np.argsort(first)
    rank = np.empty(len(order), dtype=np.int64)
    rank[order] = np.arange(len(order))
    return V[first[order]], rank[inv][np.asarray(F)]


# =============================================================================
#  Topology analysis
# =============================================================================

def _cc(n, a, b):
    g = sp.csr_matrix((np.ones(len(a), dtype=np.int8), (a, b)), shape=(n, n))
    return connected_components(g, directed=False)


def cleanup(nV, F):
    """drop degenerate faces, duplicate faces (same vertex set) and unreferenced vertices.
    returns (nV2, F2, stats, newid) where newid maps old->new vertex ids (-1 never used for kept vertices)."""
    F = np.ascontiguousarray(F, dtype=np.int64).reshape(-1, 3)
    st = {}
    deg = (F[:, 0] == F[:, 1]) | (F[:, 1] == F[:, 2]) | (F[:, 0] == F[:, 2])
    st["degenerate_faces"] = int(deg.sum())
    F = F[~deg]
    st["duplicate_faces"] = 0
    if len(F):
        S = np.sort(F, axis=1)
        o = np.lexsort((S[:, 2], S[:, 1], S[:, 0]))
        Ss = S[o]
        same = np.zeros(len(F), bool)
        same[1:] = (Ss[1:] == Ss[:-1]).all(1)
        dup = np.zeros(len(F), bool)
        dup[o[same]] = True
        st["duplicate_faces"] = int(dup.sum())
        F = F[~dup]
    used = np.zeros(nV, bool)
    used[F.reshape(-1)] = True
    st["unreferenced_vertices"] = int(nV - used.sum())
    newid = np.cumsum(used) - 1
    newid[~used] = -1
    return int(used.sum()), (newid[F] if len(F) else F), st, newid


def _edges(F, nV):
    u = F.reshape(-1)
    v = np.roll(F, -1, axis=1).reshape(-1)
    key = np.minimum(u, v) * nV + np.maximum(u, v)
    order = np.argsort(key, kind="stable")
    sk = key[order]
    start = np.nonzero(np.concatenate(([True], sk[1:] != sk[:-1])))[0]
    cnt = np.diff(np.append(start, len(sk)))
    e2 = np.nonzero(cnt == 2)[0]
    h1, h2 = order[start[e2]], order[start[e2] + 1]
    return dict(u=u, v=v, ukey=sk[start], cnt=cnt, order=order, start=start, h1=h1, h2=h2,
                same=(u[h1] == u[h2]))


def _orientation(F, ed):
    """double-cover test. returns (nonorientable_face_mask, flip_mask).
    flip_mask: faces to reverse so that every orientable piece becomes consistently oriented."""
    nF = len(F)
    h1, h2, same = ed["h1"], ed["h2"], ed["same"].astype(np.int64)
    if not same.any():
        return np.zeros(nF, bool), np.zeros(nF, bool)
    f1, f2 = h1 // 3, h2 // 3
    a = np.concatenate([2 * f1, 2 * f1 + 1])
    b = np.concatenate([2 * f2 + same, 2 * f2 + 1 - same])
    _, lab = _cc(2 * nF, a, b)
    return lab[0::2] == lab[1::2], lab[0::2] > lab[1::2]


def orient_faces(nV, F):
    """flip faces so each orientable piece is consistently oriented. returns (F2, n_flipped, n_nonorientable_faces)"""
    F = np.asarray(F, dtype=np.int64)
    non, flip = _orientation(F, _edges(F, nV))
    F2 = F.copy()
    F2[flip] = F2[flip][:, [0, 2, 1]]
    return F2, int(flip.sum()), int(non.sum())


def _fans(F, ed, nV):
    """fans (= vertex copies after splitting non-manifold vertices) using only 2-face edges"""
    nF = len(F)
    h1, h2, same = ed["h1"], ed["h2"], ed["same"]
    f1, f2 = h1 // 3, h2 // 3
    k1, k2 = h1 % 3, h2 % 3
    o1, d1 = 3 * f1 + k1, 3 * f1 + (k1 + 1) % 3
    o2, d2 = 3 * f2 + k2, 3 * f2 + (k2 + 1) % 3
    a = np.concatenate([o1, d1])
    b = np.concatenate([np.where(same, o2, d2), np.where(same, d2, o2)])
    nfan, lab = _cc(3 * nF, a, b)
    first = np.full(nfan, -1, dtype=np.int64)
    first[lab[::-1]] = np.arange(3 * nF - 1, -1, -1)
    fans_per_vertex = np.bincount(F.reshape(-1)[first], minlength=nV)
    return nfan, lab, first, fans_per_vertex


def analyze(nV, F):
    """topology report (dict). F must be (m,3) integer triangles."""
    nV, F, info, _ = cleanup(nV, F)
    nF = len(F)
    info.update(V=nV, F=nF, E=0, components=0, boundary_edges=0, boundary_loops=None, nonmanifold_edges=0,
                nonmanifold_vertices=None, inconsistent_edges=0, orientable=None, genus=None, pieces=[],
                manifold=False, val_min=0, val_mean=0.0, val_max=0)
    if nF == 0:
        return info
    ed = _edges(F, nV)
    cnt = ed["cnt"]
    E = len(cnt)
    info["E"] = E
    info["boundary_edges"] = int((cnt == 1).sum())
    info["nonmanifold_edges"] = int((cnt > 2).sum())
    info["inconsistent_edges"] = int(ed["same"].sum())
    a, b = ed["ukey"] // nV, ed["ukey"] % nV
    info["components"] = int(_cc(nV, a, b)[0])
    val = np.bincount(a, minlength=nV) + np.bincount(b, minlength=nV)
    info.update(val_min=int(val.min()), val_mean=float(val.mean()), val_max=int(val.max()))
    non_face, _ = _orientation(F, ed)
    if info["nonmanifold_edges"]:
        info["orientable"] = not bool(non_face.any())
        return info
    # ---- edge-manifold: fans / pieces / genus -------------------------------------------------
    nfan, fan, first, fpv = _fans(F, ed, nV)
    info["nonmanifold_vertices"] = int((fpv > 1).sum())
    info["manifold"] = info["nonmanifold_vertices"] == 0
    f1, f2 = ed["h1"] // 3, ed["h2"] // 3
    nP, piece = _cc(nF, f1, f2)
    Fp = np.bincount(piece, minlength=nP)
    Ep = np.bincount(piece[ed["order"][ed["start"]] // 3], minlength=nP)
    Vp = np.bincount(piece[first // 3], minlength=nP)
    Bp = np.zeros(nP, dtype=np.int64)
    be = np.nonzero(cnt == 1)[0]
    if len(be):
        hb = ed["order"][ed["start"][be]]
        fb, kb = hb // 3, hb % 3
        ca, cb = fan[3 * fb + kb], fan[3 * fb + (kb + 1) % 3]
        _, lab = _cc(nfan, ca, cb)
        touched = np.unique(np.concatenate([ca, cb]))
        _, ix = np.unique(lab[touched], return_index=True)
        Bp = np.bincount(piece[first[touched[ix]] // 3], minlength=nP)
    nonor_p = np.bincount(piece, weights=non_face.astype(np.float64), minlength=nP) > 0
    chi = Vp - Ep + Fp
    twice = 2 - chi - Bp                       # = 2g (orientable)  or k (non-orientable)
    info["boundary_loops"] = int(Bp.sum())
    info["orientable"] = bool(not nonor_p.any())
    info["pieces"] = [dict(F=int(Fp[i]), V=int(Vp[i]), E=int(Ep[i]), loops=int(Bp[i]),
                           orientable=bool(not nonor_p[i]), chi=int(chi[i]),
                           genus=int(twice[i] // 2) if not nonor_p[i] else int(twice[i])) for i in range(nP)]
    if info["orientable"]:
        info["genus"] = int(sum(p["genus"] for p in info["pieces"]))
    info["V_split"] = int(nfan)
    return info


def status_of(info):
    """one-word verdict about suitability as Edgebreaker input"""
    if info["F"] == 0:
        return "EMPTY"
    if info["nonmanifold_edges"]:
        return "NONMANIFOLD-EDGES"
    if info["nonmanifold_vertices"]:
        return "NONMANIFOLD-VERTICES"
    if info["orientable"] is False:
        return "NONORIENTABLE"
    if info["inconsistent_edges"] or info["degenerate_faces"] or info["duplicate_faces"]:
        return "FIXABLE"
    return "OK" if not info["boundary_loops"] else "OK+HOLES"


def _genus_str(info):
    if not info["pieces"]:
        return "?"
    if info["orientable"] is False:
        return "nonorientable"
    gs = [p["genus"] for p in info["pieces"]]
    return str(gs[0]) if len(gs) == 1 else "sum=%d,max=%d" % (sum(gs), max(gs))


def format_info(name, info, meta=None):
    L = ["%s" % name]
    L.append("  V=%d  E=%d  F=%d   components=%d   boundary loops=%s   genus=%s" % (
        info["V"], info["E"], info["F"], info["components"],
        "?" if info["boundary_loops"] is None else info["boundary_loops"], _genus_str(info)))
    L.append("  valence min/mean/max = %d / %.2f / %d" % (info["val_min"], info["val_mean"], info["val_max"]))
    L.append("  non-manifold edges=%d  non-manifold vertices=%s  inconsistently oriented edges=%d  orientable=%s" % (
        info["nonmanifold_edges"], info["nonmanifold_vertices"], info["inconsistent_edges"], info["orientable"]))
    cl = [(k, info[k]) for k in ("degenerate_faces", "duplicate_faces", "unreferenced_vertices") if info[k]]
    if cl:
        L.append("  removed before analysis: " + ", ".join("%s=%d" % kv for kv in cl))
    if meta and meta.get("max_poly"):
        L.append("  input had polygons up to %d sides (fan-triangulated)" % meta["max_poly"])
    if len(info["pieces"]) > 1 and len(info["pieces"]) <= 12:
        for i, p in enumerate(info["pieces"]):
            L.append("    piece %d: F=%d V=%d loops=%d genus=%d%s" % (
                i, p["F"], p["V"], p["loops"], p["genus"], "" if p["orientable"] else " (non-orientable)"))
    L.append("  => %s" % status_of(info))
    return "\n".join(L)


# =============================================================================
#  Isomorphism
# =============================================================================

def _mix(x):
    x = np.asarray(x, dtype=np.uint64)
    with np.errstate(over="ignore"):
        x = x + np.uint64(0x9E3779B97F4A7C15)
        x = (x ^ (x >> np.uint64(30))) * np.uint64(0xBF58476D1CE4E5B9)
        x = (x ^ (x >> np.uint64(27))) * np.uint64(0x94D049BB133111EB)
        return x ^ (x >> np.uint64(31))


def wl_colors(F, nV, rounds=3):
    """Weisfeiler-Lehman vertex colours: isomorphism-invariant, cheap, and a very strong filter."""
    u = F.reshape(-1)
    v = np.roll(F, -1, axis=1).reshape(-1)
    key = np.minimum(u, v) * nV + np.maximum(u, v)
    uk, cnt = np.unique(key, return_counts=True)
    a, b = uk // nV, uk % nV
    bnd = np.zeros(nV, dtype=np.int64)
    bnd[a[cnt == 1]] = 1
    bnd[b[cnt == 1]] = 1
    src = np.concatenate([a, b])
    dst = np.concatenate([b, a])
    o = np.argsort(src, kind="stable")
    src, dst = src[o], dst[o]
    val = np.bincount(src, minlength=nV)
    starts = np.concatenate(([0], np.cumsum(val)[:-1]))
    c = (val * 2 + bnd).astype(np.uint64)
    with np.errstate(over="ignore"):
        for _ in range(rounds):
            acc = np.add.reduceat(_mix(c)[dst], starts)
            c = _mix(c * np.uint64(0x2545F4914F6CDD1D) + acc)
    return c


def _halfedge_sigs(F, col):
    c = col[F]
    with np.errstate(over="ignore"):
        s = _mix(_mix(c * np.uint64(0x9E3779B97F4A7C15) + np.roll(c, -1, axis=1)) *
                 np.uint64(0xC2B2AE3D27D4EB4F) + np.roll(c, -2, axis=1))
    return s.reshape(-1)


class _HE:
    """half-edge view of a consistently oriented manifold triangle mesh. halfedge 3f+k: F[f,k] -> F[f,k+1]"""

    def __init__(self, F, nV):
        self.nV, self.nF = nV, len(F)
        u = F.reshape(-1)
        v = np.roll(F, -1, axis=1).reshape(-1)
        key = u * nV + v
        order = np.argsort(key)
        sk = key[order]
        rk = v * nV + u
        pos = np.minimum(np.searchsorted(sk, rk), len(sk) - 1)
        self.tw = np.where(sk[pos] == rk, order[pos], -1).tolist()
        self.org = u.tolist()


def _lockstep(A, B, a0, b0):
    """walk both meshes simultaneously from half-edge pair (a0,b0). returns vertex map A->B (list) or None."""
    VA, TA, VB, TB = A.org, A.tw, B.org, B.tw
    phi, inv = [-1] * A.nV, [-1] * B.nV
    fA, fB = [-1] * A.nF, [-1] * B.nF
    stack = [(a0, b0)]
    while stack:
        a, b = stack.pop()
        fa, fb = a // 3, b // 3
        if fA[fa] != -1:
            if fA[fa] != fb or phi[VA[a]] != VB[b]:
                return None
            continue
        if fB[fb] != -1:
            return None
        fA[fa], fB[fb] = fb, fa
        ba, bb = 3 * fa, 3 * fb
        ka, kb = a - ba, b - bb
        for i in range(3):
            ha, hb = ba + (ka + i) % 3, bb + (kb + i) % 3
            ua, ub = VA[ha], VB[hb]
            p = phi[ua]
            if p == -1:
                if inv[ub] != -1:
                    return None
                phi[ua], inv[ub] = ub, ua
            elif p != ub:
                return None
            ta, tb = TA[ha], TB[hb]
            if ta == -1:
                if tb != -1:
                    return None
            elif tb == -1:
                return None
            else:
                stack.append((ta, tb))
    return phi


def _prep(nV, F, label):
    """clean + validate one mesh for the exact (oriented, manifold) isomorphism test."""
    nV2, F2, st, newid = cleanup(nV, F)
    p = dict(nV=nV2, F=F2, stats=st, newid=newid, orient_fixed=0, notes=[], ok=False, reason="")
    if len(F2) == 0:
        p["reason"] = "%s has no faces" % label
        return p
    ed = _edges(F2, nV2)
    if (ed["cnt"] > 2).any():
        p["reason"] = "%s has non-manifold edges" % label
        return p
    nfan, _, _, fpv = _fans(F2, ed, nV2)
    if (fpv > 1).any():
        p["reason"] = "%s has non-manifold vertices" % label
        return p
    if ed["same"].any():
        non, flip = _orientation(F2, ed)
        if non.any():
            p["reason"] = "%s is non-orientable" % label
            return p
        F2 = F2.copy()
        F2[flip] = F2[flip][:, [0, 2, 1]]
        p["F"], p["orient_fixed"] = F2, int(flip.sum())
        p["notes"].append("%s: %d faces re-oriented (inconsistent input orientation)" % (label, int(flip.sum())))
    p["ok"] = True
    return p


def _split_components(F, nV):
    n, lab = _cc(nV, F.reshape(-1), np.roll(F, -1, axis=1).reshape(-1))
    fc = lab[F[:, 0]]
    order = np.argsort(fc, kind="stable")
    bounds = np.searchsorted(fc[order], np.arange(n + 1))
    out = []
    for c in range(n):
        idx = order[bounds[c]:bounds[c + 1]]
        if len(idx) == 0:
            continue
        verts, inv = np.unique(F[idx], return_inverse=True)
        out.append((idx, verts, np.asarray(inv).reshape(-1, 3)))
    return out


def iso_connectivity(nVA, FA, nVB, FB, mirror=False, time_limit=None):
    """Exact orientation-preserving isomorphism of two oriented manifold triangle meshes.
    Returns dict(iso: bool|None, reason, mapping (A vertex -> B vertex, -1 = unreferenced), notes).
    iso is None when the inputs are outside the supported class (key 'unsupported': non-manifold / non-orientable)
    or when time_limit (seconds) ran out - highly regular meshes that are NOT isomorphic can need a long search."""
    deadline = None if time_limit is None else time.time() + time_limit
    A, B = _prep(nVA, FA, "A"), _prep(nVB, FB, "B")
    notes = A["notes"] + B["notes"]
    for P in (A, B):
        for k in ("degenerate_faces", "duplicate_faces", "unreferenced_vertices"):
            if P["stats"][k]:
                notes.append("%s: ignored %d %s" % ("A" if P is A else "B", P["stats"][k], k.replace("_", " ")))
    if not A["ok"] or not B["ok"]:
        return dict(iso=None, reason=(A["reason"] or B["reason"]), mapping=None, notes=notes, unsupported=True)
    if A["orient_fixed"] or B["orient_fixed"]:
        mirror = True                      # orientation of each piece was arbitrary -> allow mirror images
        notes.append("input orientation was inconsistent: comparison allows mirrored components")
    FA2, FB2, nA, nB = A["F"], B["F"], A["nV"], B["nV"]
    if len(FA2) != len(FB2) or nA != nB:
        return dict(iso=False, reason="different counts: A has %d V / %d F, B has %d V / %d F" % (
            nA, len(FA2), nB, len(FB2)), mapping=None, notes=notes)
    cA, cB = wl_colors(FA2, nA), wl_colors(FB2, nB)
    if not np.array_equal(np.sort(cA), np.sort(cB)):
        return dict(iso=False, reason="vertex-neighbourhood (Weisfeiler-Lehman) histograms differ", mapping=None,
                    notes=notes)
    compA, compB = _split_components(FA2, nA), _split_components(FB2, nB)
    if len(compA) != len(compB):
        return dict(iso=False, reason="different number of components (%d vs %d)" % (len(compA), len(compB)),
                    mapping=None, notes=notes)

    def csig(comp, col):
        _, verts, loc = comp
        return (len(loc), len(verts), int(_mix(col[verts]).sum()))

    groups = {}
    for j, comp in enumerate(compB):
        groups.setdefault(csig(comp, cB), []).append(j)
    mapping = np.full(nA, -1, dtype=np.int64)
    mirrored_used = False
    for i, comp in enumerate(compA):
        sg = csig(comp, cA)
        cands = groups.get(sg)
        if not cands:
            return dict(iso=False, reason="component with %d faces has no counterpart in B" % len(comp[0]),
                        mapping=None, notes=notes)
        idxA, vertsA, locA = comp
        HA = _HE(locA, len(vertsA))
        sA = _halfedge_sigs(locA, cA[vertsA])
        us, cn = np.unique(sA, return_counts=True)
        sig = us[np.argmin(cn)]
        a0 = int(np.nonzero(sA == sig)[0][0])
        found = None
        for jj, j in enumerate(cands):
            idxB, vertsB, locB = compB[j]
            variants = [locB] + ([locB[:, [0, 2, 1]]] if mirror else [])
            for vi, Fv in enumerate(variants):
                HB = _HE(Fv, len(vertsB))
                for b0 in np.nonzero(_halfedge_sigs(Fv, cB[vertsB]) == sig)[0].tolist():
                    if deadline is not None and time.time() > deadline:
                        return dict(iso=None, mapping=None, notes=notes, reason=(
                            "search budget of %gs exhausted without finding or excluding an isomorphism "
                            "(very regular meshes make the negative case slow; raise --time-limit)" % time_limit))
                    phi = _lockstep(HA, HB, a0, b0)
                    if phi is not None:
                        found = (j, vertsA, vertsB, phi)
                        if vi == 1:
                            mirrored_used = True
                        break
                if found:
                    break
            if found:
                cands.pop(jj)
                break
        if not found:
            return dict(iso=False, reason=("same invariants but no isomorphism found for a component with %d faces"
                                           % len(idxA)) + ("" if mirror else " (try --mirror)"),
                        mapping=None, notes=notes)
        _, vA, vB, phi = found
        mapping[vA] = vB[np.asarray(phi)]
    # translate cleaned ids back to the original vertex numbering of A and B
    oldA = np.nonzero(A["newid"] >= 0)[0]
    oldB = np.nonzero(B["newid"] >= 0)[0]
    full = np.full(nVA, -1, dtype=np.int64)
    full[oldA] = oldB[mapping]
    if mirrored_used:
        notes.append("at least one component matches only as a MIRROR image (vertex map reverses orientation there)")
    return dict(iso=True, reason="", mapping=full, notes=notes)


def iso_general(nVA, FA, nVB, FB, max_faces=3000):
    """fallback for non-manifold / non-orientable meshes: isomorphism of the vertex-face incidence graph
    (ignores orientation). Needs networkx; only practical for small meshes."""
    try:
        import networkx as nx
    except ImportError:
        return dict(iso=None, reason="networkx not installed (pip install networkx)", notes=[])
    nVA, FA, _, _ = cleanup(nVA, FA)
    nVB, FB, _, _ = cleanup(nVB, FB)
    if len(FA) != len(FB) or nVA != nVB:
        return dict(iso=False, reason="different V/F counts", notes=[])
    if len(FA) > max_faces:
        return dict(iso=None, reason="%d faces is too many for the general (VF2) fallback; only counts compared" %
                    len(FA), notes=[])

    def graph(nV, F):
        G = nx.Graph()
        G.add_nodes_from((("v", i) for i in range(nV)), t=0)
        for f, tri in enumerate(F.tolist()):
            G.add_node(("f", f), t=1)
            for x in tri:
                G.add_edge(("f", f), ("v", x))
        return G

    ok = nx.is_isomorphic(graph(nVA, FA), graph(nVB, FB), node_match=lambda p, q: p["t"] == q["t"])
    return dict(iso=ok, reason="" if ok else "incidence graphs are not isomorphic", notes=[
        "general mode: orientation is ignored"])


def iso_geometric(VA, FA, VB, FB, tol=0.0, oriented=True, show=5):
    """positions are given: compare the two triangle multisets by coordinates (vertex order irrelevant).
    tol == 0: coordinates must be bit-identical.  tol > 0: vertices are matched one-to-one by nearest neighbour
    within tol (use this for quantised output, e.g. Draco; tol should be >= the quantisation step)."""
    VA, VB = np.asarray(VA, np.float64), np.asarray(VB, np.float64)
    if tol > 0:
        from scipy.spatial import cKDTree
        UA, iA = np.unique(VA, axis=0, return_inverse=True)
        UB, iB = np.unique(VB, axis=0, return_inverse=True)
        iA, iB = np.asarray(iA).reshape(-1), np.asarray(iB).reshape(-1)
        if len(UA) != len(UB):
            return dict(iso=False, notes=[], reason="different number of distinct vertex positions (%d vs %d)" % (
                len(UA), len(UB)))
        d, j = cKDTree(UB).query(UA)
        if (d > tol).any():
            return dict(iso=False, notes=[], reason="%d vertices of A have no vertex of B within tol=%g "
                                                    "(largest gap %.3g)" % (int((d > tol).sum()), tol, d.max()))
        if len(np.unique(j)) != len(UB):
            return dict(iso=False, notes=[], reason="nearest-neighbour matching within tol is not one-to-one "
                                                    "(tol larger than the vertex spacing?)")
        coords, iA, iB = UB, j[iA], iB
    else:
        coords, ids = np.unique(np.concatenate([VA, VB]), axis=0, return_inverse=True)
        ids = np.asarray(ids).reshape(-1)
        iA, iB = ids[:len(VA)], ids[len(VA):]

    def canon(F, ii):
        T = ii[np.asarray(F)]
        if oriented:
            k = np.argmin(T, axis=1)
            return T[np.arange(len(T))[:, None], (k[:, None] + np.arange(3)) % 3]
        return np.sort(T, axis=1)

    TA, TB = canon(FA, iA), canon(FB, iB)
    u, inv = np.unique(np.concatenate([TA, TB]), axis=0, return_inverse=True)
    inv = np.asarray(inv).reshape(-1)
    ca = np.bincount(inv[:len(TA)], minlength=len(u))
    cb = np.bincount(inv[len(TA):], minlength=len(u))
    diff = np.nonzero(ca != cb)[0]
    if len(diff) == 0:
        return dict(iso=True, reason="", notes=[])
    ex = ["triangle only in %s: %s" % ("A" if ca[d] > cb[d] else "B", [coords[x].tolist() for x in u[d]])
          for d in diff[:show]]
    return dict(iso=False, reason="%d distinct triangles differ (A-only %d, B-only %d)" % (
        len(diff), int(np.maximum(ca - cb, 0).sum()), int(np.maximum(cb - ca, 0).sum())), notes=ex)


# =============================================================================
#  Synthetic meshes
# =============================================================================

def _outward(V, F):
    """flip all faces if the signed volume is negative (closed, consistently oriented meshes)"""
    P = V[F]
    vol = np.einsum("ij,ij->i", P[:, 0], np.cross(P[:, 1], P[:, 2])).sum()
    return F if vol >= 0 else F[:, [0, 2, 1]]


def _hull(P):
    from scipy.spatial import ConvexHull
    P = np.asarray(P, dtype=np.float64)
    F = ConvexHull(P).simplices.astype(np.int64)
    F, _, _ = orient_faces(len(P), F)
    return P, _outward(P, F)


def tetra():
    return _hull([(1, 1, 1), (1, -1, -1), (-1, 1, -1), (-1, -1, 1)])


def octa():
    return _hull([(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)])


def cube():
    return _hull([(x, y, z) for x in (-1, 1) for y in (-1, 1) for z in (-1, 1)])


def icosa():
    t = (1 + 5 ** 0.5) / 2
    P = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
         (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    return _hull(P)


def subdivide(V, F, levels=1, sphere=False):
    """midpoint 1->4 subdivision; topology (genus, boundary) is preserved, faces x4 per level."""
    V = np.asarray(V, dtype=np.float64)
    F = np.asarray(F, dtype=np.int64)
    for _ in range(levels):
        nV = len(V)
        u = F.reshape(-1)
        v = np.roll(F, -1, axis=1).reshape(-1)
        uk, inv = np.unique(np.minimum(u, v) * nV + np.maximum(u, v), return_inverse=True)
        inv = np.asarray(inv).reshape(-1, 3)
        M = (V[uk // nV] + V[uk % nV]) / 2
        if sphere:
            M /= np.linalg.norm(M, axis=1, keepdims=True)
        m0, m1, m2 = nV + inv[:, 0], nV + inv[:, 1], nV + inv[:, 2]
        a, b, c = F[:, 0], F[:, 1], F[:, 2]
        F = np.concatenate([np.stack([a, m0, m2], 1), np.stack([b, m1, m0], 1),
                            np.stack([c, m2, m1], 1), np.stack([m0, m1, m2], 1)])
        V = np.concatenate([V, M])
    return V, F


def sphere(levels=3):
    V, F = icosa()
    V = V / np.linalg.norm(V, axis=1, keepdims=True)
    return subdivide(V, F, levels, sphere=True)


def torus_grid(m=16, n=8, R=2.0, r=0.7, offset=(0, 0, 0)):
    i, j = np.meshgrid(np.arange(m), np.arange(n), indexing="ij")
    th, ph = 2 * np.pi * i / m, 2 * np.pi * j / n
    V = np.stack([(R + r * np.cos(ph)) * np.cos(th), (R + r * np.cos(ph)) * np.sin(th), r * np.sin(ph)], -1)
    V = V.reshape(-1, 3) + np.asarray(offset)
    a = (i * n + j).ravel()
    b = (((i + 1) % m) * n + j).ravel()
    c = (((i + 1) % m) * n + (j + 1) % n).ravel()
    d = (i * n + (j + 1) % n).ravel()
    F = np.concatenate([np.stack([a, b, c], 1), np.stack([a, c, d], 1)])
    return V, _outward(V, F)


def csaszar():
    """7-vertex triangulation of the torus: every pair of vertices is joined by an edge."""
    F = [(i, (i + 1) % 7, (i + 3) % 7) for i in range(7)] + [(i, (i + 3) % 7, (i + 2) % 7) for i in range(7)]
    F, _, _ = orient_faces(7, np.array(F, dtype=np.int64))
    ang = 2 * np.pi * np.arange(7) / 7
    V = np.stack([np.cos(ang), np.sin(ang), 0.3 * (np.arange(7) % 2)], 1)   # combinatorial object; positions arbitrary
    return V, F


def genus_g(g, m=10, n=6):
    """chain of g tori joined by tubes (connected sum) -> closed orientable surface of genus g"""
    if g == 0:
        return sphere(2)
    Vs, Fs, off, links = [], [], 0, []
    for k in range(g):
        V, F = torus_grid(m, n, offset=(5.0 * k, 0, 0))
        fr, fl = 0, (m // 2) * n                 # +x side / -x side of the torus: far apart, no shared vertices
        rm = []
        if k > 0:
            rm.append(fl)
        if k < g - 1:
            rm.append(fr)
        keep = np.ones(len(F), bool)
        keep[rm] = False
        links.append((F[fl] + off if k > 0 else None, F[fr] + off if k < g - 1 else None))
        Fs.append(F[keep] + off)
        Vs.append(V)
        off += len(V)
    tube = []
    for k in range(g - 1):
        a, b, c = links[k][1]
        a2, b2, c2 = links[k + 1][0]
        for q in ((a, b, c2, a2), (b, c, b2, c2), (c, a, a2, b2)):
            tube += [(q[0], q[1], q[2]), (q[0], q[2], q[3])]
    F = np.concatenate(Fs + [np.array(tube, dtype=np.int64).reshape(-1, 3)])
    return np.concatenate(Vs), F


def capped_tube(rings=2000, k=3):
    """very long thin sphere-like mesh (deep Edgebreaker traversal / recursion stress)"""
    ang = 2 * np.pi * np.arange(k) / k
    V = [(0, 0, -0.5)]
    for i in range(rings):
        V += [(0.1 * np.cos(t), 0.1 * np.sin(t), i * 0.01) for t in ang]
    V.append((0, 0, rings * 0.01 + 0.5))
    F = []
    for j in range(k):
        j1 = (j + 1) % k
        F.append((0, 1 + j1, 1 + j))
    for i in range(rings - 1):
        for j in range(k):
            j1 = (j + 1) % k
            a, b, c, d = 1 + i * k + j, 1 + i * k + j1, 1 + (i + 1) * k + j1, 1 + (i + 1) * k + j
            F += [(a, b, c), (a, c, d)]
    last = 1 + (rings - 1) * k
    for j in range(k):
        F.append((len(V) - 1, last + j, last + (j + 1) % k))
    V, F = np.array(V, dtype=np.float64), np.array(F, dtype=np.int64)
    return V, _outward(V, F)


def disk_fan(n=12):
    ang = 2 * np.pi * np.arange(n) / n
    V = np.vstack([[0, 0, 0], np.stack([np.cos(ang), np.sin(ang), np.zeros(n)], 1)])
    F = np.array([(0, 1 + i, 1 + (i + 1) % n) for i in range(n)], dtype=np.int64)
    return V, F


def mobius(n=12):
    V, F = [], []
    for i in range(n):
        t = np.pi * i / n
        for s in (-0.3, 0.3):
            r = 1 + s * np.cos(t)
            V.append((r * np.cos(2 * t), r * np.sin(2 * t), s * np.sin(t)))
    for i in range(n):
        a, b = 2 * i, 2 * i + 1
        if i < n - 1:
            a2, b2 = 2 * i + 2, 2 * i + 3
        else:
            a2, b2 = 1, 0                      # the twist
        F += [(a, b, b2), (a, b2, a2)]
    return np.array(V), np.array(F, dtype=np.int64)


def bowtie():
    """two tetrahedra sharing exactly one vertex (non-manifold vertex, manifold edges)"""
    V1, F1 = tetra()
    V2, F2 = tetra()
    V2 = V2 + np.array([3.0, 0, 0])
    m = np.array([0, 4, 5, 6])                 # 2nd tetra: its vertex 0 is glued onto vertex 0 of the first
    return np.vstack([V1, V2[1:]]), np.vstack([F1, m[F2]])


def three_fin():
    V = np.array([(0, 0, 0), (1, 0, 0), (0.5, 1, 0), (0.5, -1, 0.5), (0.5, 0, 1.5)], dtype=np.float64)
    return V, np.array([(0, 1, 2), (1, 0, 3), (0, 1, 4)], dtype=np.int64)


def two_tetra():
    V, F = tetra()
    return np.vstack([V, V + 5.0]), np.vstack([F, F + 4])


def synthetic_suite():
    S = {"tetra": tetra(), "octa": octa(), "cube": cube(), "icosa": icosa(), "sphere_L3": sphere(3),
         "torus_16x8": torus_grid(16, 8), "csaszar_torus": csaszar(), "genus2": genus_g(2), "genus3": genus_g(3),
         "genus8": genus_g(8), "long_tube_6000": capped_tube(2000, 3), "two_tetra": two_tetra(),
         "bad_disk_fan": disk_fan(), "bad_mobius": mobius(), "bad_bowtie": bowtie(), "bad_three_fin": three_fin()}
    return S


# =============================================================================
#  Downloading
# =============================================================================

UA = {"User-Agent": "Mozilla/5.0 (meshkit mesh fetcher)"}
ROWS = []        # report rows


def _fail_fast(e):
    """errors for which retrying the same URL is pointless (DNS failure, 403/404...)"""
    if isinstance(e, urllib.error.HTTPError):
        return e.code in (400, 401, 403, 404, 410)
    return isinstance(e, socket.gaierror) or isinstance(getattr(e, "reason", None), socket.gaierror)


def http_get(url, dest, retries=3, mirrors=()):
    """download url -> dest (skipped if dest exists). If url fails, the mirror URLs are tried in order."""
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print("   have      " + dest)
        return dest
    os.makedirs(os.path.dirname(dest) or ".", exist_ok=True)
    tmp, tried = dest + ".part", []
    for u in (url,) + tuple(mirrors):
        last = None
        for attempt in range(retries):
            try:
                req = urllib.request.Request(u, headers=UA)
                with urllib.request.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
                    total, done = int(r.headers.get("Content-Length") or 0), 0
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        f.write(chunk)
                        done += len(chunk)
                        if total:
                            sys.stdout.write("\r   download  %s  %5.1f%% of %.1f MB   " % (
                                os.path.basename(dest), 100.0 * done / total, total / 1e6))
                            sys.stdout.flush()
                os.replace(tmp, dest)
                print("\r   downloaded %s (%.1f MB) from %s                    " % (
                    os.path.basename(dest), done / 1e6, re.sub(r"^\w+://([^/]+)/.*", r"\1", u)))
                return dest
            except Exception as e:  # noqa
                last = e
                if os.path.exists(tmp):
                    os.remove(tmp)
                if _fail_fast(e):
                    break
                time.sleep(2 * (attempt + 1))
        tried.append("%s (%s)" % (u, getattr(last, "reason", last)))
        if u != (url,) + tuple(mirrors) and len(mirrors):
            print("   ! %s failed: %s" % (u, getattr(last, "reason", last)))
    raise RuntimeError("download failed, tried: " + "; ".join(tried))


def scrape_links(url):
    req = urllib.request.Request(url, headers=UA)
    html = urllib.request.urlopen(req, timeout=60).read().decode("latin1")
    return [urljoin(url, h) for h in re.findall(r"""href\s*=\s*["']([^"']+)["']""", html, re.I)]


def register(name, source, V, F, meta, args, path=None, note=""):
    """analyse a mesh (unless too big) and add a report row"""
    row = dict(name=name, source=source, file=path or "", V=len(V), F=len(F), E="", components="", loops="",
               genus="", status="not analysed", note=note)
    if meta and meta.get("max_poly"):
        row["note"] = (row["note"] + " polygons<=%d fan-triangulated" % meta["max_poly"]).strip()
    if not args.no_analyze and len(F) <= args.analyze_max_faces:
        try:
            info = analyze(len(V), F)
            row.update(V=info["V"], F=info["F"], E=info["E"], components=info["components"],
                       loops=info["boundary_loops"], genus=_genus_str(info), status=status_of(info))
            extra = []
            if info["nonmanifold_edges"]:
                extra.append("nm-edges=%d" % info["nonmanifold_edges"])
            if info["nonmanifold_vertices"]:
                extra.append("nm-verts=%d" % info["nonmanifold_vertices"])
            if info["inconsistent_edges"]:
                extra.append("misoriented-edges=%d" % info["inconsistent_edges"])
            if extra:
                row["note"] = (row["note"] + " " + " ".join(extra)).strip()
        except MemoryError:
            row["status"] = "out of memory while analysing"
    elif len(F) > args.analyze_max_faces:
        row["status"] = "skipped analysis (> %d faces; use --analyze-max-faces)" % args.analyze_max_faces
    ROWS.append(row)
    print("   %-28s V=%-9s F=%-9s genus=%-12s %s" % (name, row["V"], row["F"], row["genus"], row["status"]))


def _convert_and_register(name, source, V, F, meta, out_dir, args, note=""):
    path = save_mesh(os.path.join(out_dir, name), V, F, args.format, comment="%s (%s) via meshkit" % (name, source))
    register(name, source, V, F, meta, args, path, note)


def _have(args, *paths):
    """True (and a message) if the output mesh is already on disk - then nothing is downloaded or converted."""
    if getattr(args, "force", False):
        return False
    for p in paths:
        if os.path.isfile(p) and os.path.getsize(p) > 0:
            print("   already have %s - skipping" % p)
            return True
    return False


def _have_glob(args, directory, prefix, ext):
    if getattr(args, "force", False) or not os.path.isdir(directory):
        return False
    hit = [f for f in os.listdir(directory) if f.startswith(prefix) and f.endswith("." + ext)]
    if hit:
        print("   already have %d mesh(es) %s*.%s in %s - skipping" % (len(hit), prefix, ext, directory))
    return bool(hit)


def _wanted(name, args):
    if args.only and not any(o in name for o in args.only):
        return False
    return not any(x in name for x in args.exclude)


STANFORD_BASE = "http://graphics.stanford.edu/pub/3Dscanrep/"
STANFORD_DATA = "http://graphics.stanford.edu/data/3Dscanrep/"
# name: (url, member inside the archive or None for a bare .ply.gz, approx MB)
STANFORD = {
    "bunny": (STANFORD_BASE + "bunny.tar.gz", "bunny/reconstruction/bun_zipper.ply", 5),
    "drill_bit": (STANFORD_BASE + "drill.tar.gz", "drill/reconstruction/drill_shaft_vrip.ply", 1),
    "drill_bit_zippered": (STANFORD_BASE + "drill.tar.gz", "drill/reconstruction/drill_shaft_zip.ply", 0),  # exact name only
    "happy_buddha": (STANFORD_BASE + "happy/happy_recon.tar.gz", "happy_recon/happy_vrip.ply", 15),
    "dragon": (STANFORD_BASE + "dragon/dragon_recon.tar.gz", "dragon_recon/dragon_vrip.ply", 11),
    "armadillo": (STANFORD_BASE + "armadillo/Armadillo.ply.gz", None, 4),
    "lucy": (STANFORD_DATA + "lucy.tar.gz", "lucy.ply", 322),
    "asian_dragon": (STANFORD_DATA + "xyzrgb/xyzrgb_dragon.ply.gz", None, 71),
    "thai_statue": (STANFORD_DATA + "xyzrgb/xyzrgb_statuette.ply.gz", None, 106),
    "vellum_manuscript": (STANFORD_DATA + "xyzrgb/xyzrgb_manuscript.ply.gz", None, 41),
}


def _pick_member(names, want):
    if want in names:
        return want
    ply = [n for n in names if n.lower().endswith(".ply")]
    base = os.path.basename(want).lower()
    for n in ply:
        if os.path.basename(n).lower() == base:
            return n
    pref = [n for n in ply if any(t in n.lower() for t in ("vrip", "zip", "recon"))]
    return (pref or ply or [None])[0]


def fetch_stanford(args):
    dl = os.path.join(args.out, "_downloads", "stanford")
    od = os.path.join(args.out, "stanford")
    for name, (url, member, mb) in STANFORD.items():
        if not _wanted(name, args):
            continue
        print(" * stanford/%s (~%d MB)" % (name, mb))
        if _have(args, os.path.join(od, "%s.%s" % (name, args.format))):
            continue
        if args.dry_run:
            print("   would fetch " + url)
            continue
        try:
            try:
                arc = http_get(url, os.path.join(dl, os.path.basename(url)))
            except RuntimeError:
                alt = [l for l in scrape_links(STANFORD_DATA + "3Dscanrep.html")
                       if os.path.basename(l) == os.path.basename(url)]
                if not alt:
                    raise
                arc = http_get(alt[0], os.path.join(dl, os.path.basename(url)))
            if member is None:
                V, F, meta = read_ply(arc)
            else:
                with tarfile.open(arc, "r:gz") as tf:
                    m = _pick_member(tf.getnames(), member)
                    if m is None or (name.endswith("zippered") and os.path.basename(m) != os.path.basename(member)):
                        raise RuntimeError("expected member %s not found in archive" % member)
                    V, F, meta = parse_ply(tf.extractfile(m).read())
            note = {"bunny": "5 holes at the bottom", "happy_buddha": "small bridges -> higher genus",
                    "dragon": "many small holes", "lucy": "bridges; maybe not manifold"}.get(name, "")
            _convert_and_register(name, "stanford", V, F, meta, od, args, note)
            del V, F
        except Exception as e:  # noqa
            print("   !! %s failed: %s" % (name, e))
            ROWS.append(dict(name=name, source="stanford", status="FAILED: %s" % e))


GT_BASE = "https://sites.cc.gatech.edu/projects/large_models/"
GT_DATA = "http://www-static.cc.gatech.edu/data_files/large_models/"
# Models whose pages offer a triangle mesh.  (gcanyon and ps - Grand Canyon, Puget Sound - are elevation IMAGES, no mesh.)
# Direct file names are only a fallback if the page cannot be scraped; dragon.ply.gz and angel/angel.obj.gz are
# confirmed from the site, the rest follow the same pattern.
GT_DIRECT = {"bunny": "bunny.ply.gz", "blade": "blade.ply.gz", "hand": "hand.ply.gz", "dragon": "dragon.ply.gz",
             "happy": "happy.ply.gz", "horse": "horse.ply.gz", "angel": "angel/angel.obj.gz"}
GT_HOSTS = ["https://sites.cc.gatech.edu/data_files/large_models/", "https://www.cc.gatech.edu/data_files/large_models/",
            "http://www.cc.gatech.edu/data_files/large_models/"]       # guesses: the pages link to www-static.cc.gatech.edu
GT_MESH_LINK = re.compile(r"\.(ply|obj)(\.gz)?$", re.I)          # Angel is published as OBJ, the others as PLY
GT_NOT_MODELS = ("about", "ply", "links", "contrib", "index", "gcanyon", "ps")


def _gt_rel(url):
    m = re.search(r"/data_files/large_models/(.+)$", url)
    return m.group(1) if m else None


def _probe_gt_host(args, sample_url):
    """The archive pages link to www-static.cc.gatech.edu, which no longer resolves for some of us.
    Find a host that actually serves the files: --gt-data-url first, then the page's own host, then guesses.
    Returns (base_url or None, [(candidate base, reason it failed)])."""
    rel = _gt_rel(sample_url)
    cands = ([args.gt_data_url.rstrip("/") + "/"] if getattr(args, "gt_data_url", None) else [])
    cands += [sample_url[:len(sample_url) - len(rel)]] + GT_HOSTS
    seen, errs = set(), []
    for base in cands:
        if base in seen:
            continue
        seen.add(base)
        try:
            with urllib.request.urlopen(urllib.request.Request(base + rel, headers=dict(UA, Range="bytes=0-0")),
                                        timeout=20) as r:
                r.read(1)
            return base, errs
        except Exception as e:  # noqa
            errs.append((base, str(getattr(e, "reason", e))))
    return None, errs


def fetch_gt(args):
    od = os.path.join(args.out, "georgia_tech")
    dl = os.path.join(args.out, "_downloads", "georgia_tech")
    print(" * georgia tech large models archive (%s)" % GT_BASE)
    try:                                                        # model pages are listed on the index page
        pages = sorted({l.split("#")[0] for l in scrape_links(GT_BASE + "index.html")
                        if l.startswith(GT_BASE) and l.endswith(".html")
                        and os.path.basename(l)[:-5] not in GT_NOT_MODELS})
    except Exception as e:  # noqa
        print("   index page not readable (%s); using the built-in model list" % e)
        pages = []
    pages = pages or [GT_BASE + m + ".html" for m in ("bunny", "blade", "hand", "dragon", "happy", "horse",
                                                       "vis_skin", "vis_bone", "angel")]
    files, no_link = {}, []
    for p in pages:
        try:
            links = [l for l in scrape_links(p) if GT_MESH_LINK.search(l)]
        except Exception:  # noqa
            links = []
        for l in links:
            files[os.path.basename(l)] = l                       # the mesh files live on www-static.cc.gatech.edu
        if not links:
            no_link.append(os.path.basename(p)[:-5])
    for m in no_link:                                            # page unreadable / link not found -> try direct name
        if m in GT_DIRECT:
            files[os.path.basename(GT_DIRECT[m])] = GT_DATA + GT_DIRECT[m]
        else:
            print("   no mesh link found on %s.html (not a mesh, or the file list is not visible to the scraper)" % m)
    if not files:
        print("   !! no mesh files found - download them by hand into %s and run `meshkit.py info`" % od)
        return
    items = [(fn, url, "gt_" + re.sub(r"\.(ply|obj)(\.gz)?$", "", fn, flags=re.I)) for fn, url in sorted(files.items())]
    items = [t for t in items if _wanted(t[2], args)]
    out_path = lambda name: os.path.join(od, "%s.%s" % (name, args.format))
    need_net = [t for t in items if not (not args.force and os.path.isfile(out_path(t[2])))
                and not os.path.exists(os.path.join(dl, t[0]))]
    base, reachable = None, True
    if need_net and not args.dry_run and _gt_rel(need_net[0][1]):      # probe once instead of failing file by file
        sample = need_net[0][1]
        base, errs = _probe_gt_host(args, sample)
        if base is None:
            reachable = False
            print("   !! no host serving the Georgia Tech files answered (%d files affected):" % len(need_net))
            for b_, e_ in errs:
                print("      %s -> %s" % (b_, e_))
            print("   The model pages link to www-static.cc.gatech.edu, which does not resolve. If you find the files\n"
                  "   elsewhere use  --gt-data-url <folder URL>  (the folder that contains e.g. blade.ply.gz), or save\n"
                  "   them from a browser to  %s  (same file names) and run fetch again." % dl)
        else:
            orig = sample[:len(sample) - len(_gt_rel(sample))]
            if base != orig:
                print("   files are served from %s (the pages still link to %s)" % (base, orig))
    skipped = []
    for fn, url, name in items:
        print(" * georgia_tech/%s" % fn)
        if _have(args, out_path(name)):
            continue
        if args.dry_run:
            print("   would fetch " + url)
            continue
        local = os.path.join(dl, fn)
        if not os.path.exists(local) and not reachable:
            skipped.append(fn)
            continue
        rel = _gt_rel(url)
        try:
            arc = http_get((base + rel) if (base and rel) else url, local)
            V, F, meta = load_mesh(arc)
            _convert_and_register(name, "georgia_tech", V, F, meta, od, args)
        except Exception as e:  # noqa
            print("   !! %s failed: %s" % (fn, e))
            ROWS.append(dict(name=name, source="georgia_tech", status="FAILED: %s" % e))
    if skipped:
        print("   skipped %d file(s) (no reachable host): %s" % (len(skipped), ", ".join(skipped)))
        ROWS.append(dict(name="georgia_tech (%d files)" % len(skipped), source="georgia_tech",
                         status="FAILED: no reachable host; skipped " + ", ".join(skipped)))


def fetch_jacobson(args):
    api = "https://api.github.com/repos/alecjacobson/common-3d-test-models/contents/data"
    od = os.path.join(args.out, "jacobson")
    dl = os.path.join(args.out, "_downloads", "jacobson")
    print(" * alecjacobson/common-3d-test-models (GitHub API listing)")
    try:
        import json
        listing = json.loads(urllib.request.urlopen(urllib.request.Request(api, headers=UA), timeout=60).read())
        files = [(e["name"], e["download_url"]) for e in listing if e.get("type") == "file" and e.get("download_url")]
    except Exception as e:  # noqa
        print("   API listing failed (%s); trying `git clone --depth 1`" % e)
        try:
            tmp = os.path.join(dl, "repo")
            if not os.path.isdir(tmp):
                subprocess.check_call(["git", "clone", "--depth", "1",
                                       "https://github.com/alecjacobson/common-3d-test-models", tmp])
            files = [(f, "file://" + os.path.abspath(os.path.join(tmp, "data", f)))
                     for f in os.listdir(os.path.join(tmp, "data"))]
        except Exception as e2:  # noqa
            print("   !! git clone failed too: %s" % e2)
            return
    for fn, url in sorted(files):
        stem, ext = os.path.splitext(fn)
        if ext.lower() not in (".obj", ".ply", ".off"):
            continue
        name = "jacobson_" + stem
        if not _wanted(name, args):
            continue
        print(" * jacobson/%s" % fn)
        if _have(args, os.path.join(od, fn) if (ext.lower() == ".obj" and args.format == "obj")
                 else os.path.join(od, "%s.%s" % (name, args.format))):
            continue
        if args.dry_run:
            continue
        try:
            if url.startswith("file://"):
                src = url[7:]
            else:
                src = http_get(url, os.path.join(od if ext.lower() == ".obj" else dl, fn))
            V, F, meta = load_mesh(src)
            if ext.lower() == ".obj" and args.format == "obj":
                register(name, "jacobson", V, F, meta, args, src)
            else:
                _convert_and_register(name, "jacobson", V, F, meta, od, args)
        except Exception as e:  # noqa
            print("   !! %s failed: %s" % (fn, e))
            ROWS.append(dict(name=name, source="jacobson", status="FAILED: %s" % e))


CRANE = "https://www.cs.cmu.edu/~kmcrane/Projects/ModelRepository/"
CRANE_NOTES = {"yeahright": "genus 131 (stated by the author)", "pittsburghbridge": "genus 3 remesh (author) ",
               "csaszar": "7-vertex torus; original is NOT oriented", "KleinBox": "Klein bottle -> non-orientable",
               "Nefertiti.obj": "~2M triangles", "spot": "genus 0", "oloid": "developable surface"}
CRANE_ZIPS = ["spot", "bob", "blub", "ogre", "pig", "yeahright", "pittsburghbridge", "csaszar", "KleinBox",
              "oloid", "constant-width", "crumpleddevelopable", "desertrose", "snakeboard", "Nefertiti.obj"]


def fetch_crane(args):
    od = os.path.join(args.out, "crane")
    dl = os.path.join(args.out, "_downloads", "crane")
    for z in CRANE_ZIPS:
        if not _wanted("crane_" + z, args):
            continue
        print(" * crane/%s.zip" % z)
        if _have_glob(args, od, "crane_%s__" % z.replace(".obj", ""), args.format):
            continue
        if args.dry_run:
            continue
        try:
            arc = http_get(CRANE + z + ".zip", os.path.join(dl, z + ".zip"))
            with zipfile.ZipFile(arc) as zf:
                for m in zf.namelist():
                    stem, ext = os.path.splitext(os.path.basename(m))
                    if ext.lower() not in (".obj", ".ply", ".off") or not stem:
                        continue
                    tmp = os.path.join(dl, "x_" + os.path.basename(m))
                    with zf.open(m) as src, open(tmp, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    V, F, meta = load_mesh(tmp)
                    name = "crane_%s__%s" % (z.replace(".obj", ""), stem)
                    if ext.lower() == ".obj" and args.format == "obj":
                        os.makedirs(od, exist_ok=True)
                        dest = os.path.join(od, name + ".obj")
                        shutil.move(tmp, dest)
                        register(name, "crane", V, F, meta, args, dest, CRANE_NOTES.get(z, ""))
                    else:
                        os.remove(tmp)
                        _convert_and_register(name, "crane", V, F, meta, od, args, CRANE_NOTES.get(z, ""))
                    if os.path.exists(tmp):
                        os.remove(tmp)
        except Exception as e:  # noqa
            print("   !! %s failed: %s" % (z, e))
            ROWS.append(dict(name="crane_" + z, source="crane", status="FAILED: %s" % e))


def fetch_synthetic(args):
    od = os.path.join(args.out, "synthetic")
    print(" * synthetic meshes")
    for name, (V, F) in synthetic_suite().items():
        if _wanted("synth_" + name, args) and not args.dry_run:
            note = {"csaszar_torus": "7 vertices, 14 faces", "long_tube_6000": "deep traversal",
                    "genus8": "connected sum of 8 tori"}.get(name, "")
            _convert_and_register("synth_" + name, "synthetic", V, F, {}, od, args, note)


def fetch_thingi(args):
    try:
        import thingi10k
    except ImportError:
        print(" * thingi10k: `pip install thingi10k` first (skipping)")
        return
    od = os.path.join(args.out, "thingi10k")
    print(" * thingi10k: scanning up to %d closed models with <= %d vertices (this takes a while)" % (
        args.thingi_scan, args.thingi_max_vertices))
    if args.dry_run:
        return
    thingi10k.init()
    good, bad = [], {}
    for n, entry in enumerate(thingi10k.dataset(closed=True, num_vertices=(None, args.thingi_max_vertices))):
        if n >= args.thingi_scan:
            break
        try:
            V, F = thingi10k.load_file(entry["file_path"])
            V, F = weld(np.asarray(V), np.asarray(F))
            info = analyze(len(V), F)
        except Exception:  # noqa
            continue
        st = status_of(info)
        rec = (entry["file_id"], info, V, F)
        if st in ("OK", "FIXABLE") and info["orientable"]:
            good.append((info["genus"] or 0, rec))
        elif st != "OK+HOLES":
            bad.setdefault(st, []).append(rec)
    good.sort(key=lambda t: -t[0])
    picks = [(r, "") for _, r in good[:args.thingi_top]]
    k = 0
    while k < args.thingi_bad and any(bad.values()):          # round-robin over failure classes
        for st in sorted(bad):
            if bad[st] and k < args.thingi_bad:
                picks.append((bad[st].pop(0), st))
                k += 1
    for (fid, info, V, F), st in picks:
        name = "thingi_%s_g%s%s" % (fid, info["genus"] if info["genus"] is not None else "x",
                                    "_" + st.lower() if st else "")
        nV2, F2, _, newid = cleanup(len(V), F)
        _convert_and_register(name, "thingi10k", V[newid >= 0], F2, {}, od, args, "welded STL soup")


def write_report(args):
    if not ROWS:
        return
    path = os.path.join(args.out, "report.csv")
    cols = ["name", "source", "V", "E", "F", "components", "loops", "genus", "status", "note", "file"]
    os.makedirs(args.out, exist_ok=True)
    old = []
    if os.path.isfile(path):                      # keep rows of meshes that were skipped (already on disk) this run
        with open(path, newline="") as f:
            old = [r for r in csv.DictReader(f) if r.get("name") not in {x["name"] for x in ROWS}]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(old + ROWS)
    print("\nreport written to %s (%d new rows, %d kept from earlier runs)" % (path, len(ROWS), len(old)))
    print("%-46s %9s %9s %5s %5s %-12s %s" % ("name", "V", "F", "comp", "loops", "genus", "status"))
    for r in ROWS:
        print("%-46s %9s %9s %5s %5s %-12s %s %s" % (r["name"][:46], r.get("V", ""), r.get("F", ""),
                                                     r.get("components", ""), r.get("loops", ""), r.get("genus", ""),
                                                     r.get("status", ""), r.get("note", "")))


# =============================================================================
#  CLI
# =============================================================================

def cmd_fetch(args):
    args.exclude = [x for x in (args.exclude or "").split(",") if x]
    args.only = [x for x in (args.only or "").split(",") if x]
    sets = [s.strip() for s in args.sets.split(",")]
    table = {"stanford": fetch_stanford, "gt": fetch_gt, "jacobson": fetch_jacobson, "crane": fetch_crane,
             "synthetic": fetch_synthetic, "thingi": fetch_thingi}
    for s in sets:
        if s not in table:
            sys.exit("unknown set %r (choose from %s)" % (s, ", ".join(table)))
        table[s](args)
    write_report(args)


def cmd_info(args):
    for p in args.files:
        V, F, meta = load_mesh(p)
        if args.weld:
            V, F = weld(V, F)
        info = analyze(len(V), F)
        print(format_info(p, info, meta))
        if args.write_clean:
            nV, F2, _, newid = cleanup(len(V), F)
            F2, nflip, _ = orient_faces(nV, F2)
            V2 = V[np.nonzero(newid >= 0)[0]]
            write_obj(args.write_clean, V2, F2)
            print("  wrote cleaned/oriented mesh to %s (re-oriented %d faces)" % (args.write_clean, nflip))


def _summary_line(tag, info):
    return "  %s: V=%d E=%d F=%d comps=%d loops=%s genus=%s val max=%d" % (
        tag, info["V"], info["E"], info["F"], info["components"], info["boundary_loops"], _genus_str(info),
        info["val_max"])


def cmd_iso(args):
    VA, FA, _ = load_mesh(args.a)
    VB, FB, _ = load_mesh(args.b)
    if args.weld:
        VA, FA = weld(VA, FA)
        VB, FB = weld(VB, FB)
    print("A: %s\nB: %s" % (args.a, args.b))
    print(_summary_line("A", analyze(len(VA), FA)))
    print(_summary_line("B", analyze(len(VB), FB)))
    t0 = time.time()
    if args.geometric:
        r = iso_geometric(VA, FA, VB, FB, tol=args.tol, oriented=not args.unoriented)
        mode = "geometric (same coordinates, same triangles%s)" % ("" if not args.unoriented else ", orientation ignored")
    else:
        r = iso_connectivity(len(VA), FA, len(VB), FB, mirror=args.mirror, time_limit=args.time_limit)
        mode = "connectivity (orientation preserving%s)" % (", mirror allowed" if args.mirror else "")
        if r.get("unsupported"):
            print("  exact test unavailable: %s -> falling back to general incidence-graph isomorphism" % r["reason"])
            r = iso_general(len(VA), FA, len(VB), FB, args.general_max_faces)
            mode = "general (incidence graph, orientation ignored)"
    for n in r.get("notes", []):
        print("  note: " + n)
    if r["iso"] is not True and not args.weld:
        for tag, V in (("A", VA), ("B", VB)):
            dup = len(V) - len(np.unique(V, axis=0))
            if dup:
                print("  hint: %s has %d vertices at duplicate positions (seams / unwelded soup) - try --weld" % (tag, dup))
    verdict = {True: "ISOMORPHIC", False: "NOT isomorphic", None: "INCONCLUSIVE"}[r["iso"]]
    print("mode: %s\nresult: %s%s   (%.2fs)" % (mode, verdict, "" if not r["reason"] else " - " + r["reason"],
                                                time.time() - t0))
    if r["iso"] and args.map and r.get("mapping") is not None:
        np.savetxt(args.map, np.stack([np.arange(len(r["mapping"])), r["mapping"]], 1), fmt="%d")
        print("vertex map A->B written to " + args.map + " (0-based, -1 = unreferenced)")
    sys.exit({True: 0, False: 1}.get(r["iso"], 2))


def cmd_synth(args):
    for name, (V, F) in synthetic_suite().items():
        p = save_mesh(os.path.join(args.out, "synth_" + name), V, F, args.format)
        print("%-40s %s" % (p, status_of(analyze(len(V), F))))


def cmd_subdivide(args):
    V, F, _ = load_mesh(args.inp)
    V2, F2 = subdivide(V, F, args.levels)
    write_obj(args.out, V2, F2)
    print("%s: %d -> %d faces" % (args.out, len(F), len(F2)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    f = sub.add_parser("fetch", help="download + convert + analyse the standard test sets")
    f.add_argument("--out", default="meshes")
    f.add_argument("--sets", default="stanford,gt,jacobson,crane,synthetic,thingi")
    f.add_argument("--format", choices=["obj", "ply"], default="obj", help="output format (ply = ASCII PLY)")
    f.add_argument("--exclude", help="comma list of name substrings to skip, e.g. lucy,thai")
    f.add_argument("--only", help="comma list of name substrings to keep")
    f.add_argument("--dry-run", action="store_true", help="only list what would be fetched")
    f.add_argument("--gt-data-url", help="folder URL holding the Georgia Tech files (dragon.ply.gz, angel/angel.obj.gz ...); "
                                         "tried before the built-in alternatives")
    f.add_argument("--force", action="store_true", help="re-download / re-convert even if the output file exists")
    f.add_argument("--no-analyze", action="store_true")
    f.add_argument("--analyze-max-faces", type=int, default=12_000_000,
                   help="skip topology analysis above this size (Lucy needs ~8 GB RAM)")
    f.add_argument("--thingi-top", type=int, default=40, help="export this many highest-genus clean models")
    f.add_argument("--thingi-bad", type=int, default=12, help="export this many broken models (negative tests)")
    f.add_argument("--thingi-scan", type=int, default=3000, help="how many Thingi10K models to scan")
    f.add_argument("--thingi-max-vertices", type=int, default=200000)
    f.set_defaults(fn=cmd_fetch)

    i = sub.add_parser("info", help="topology report for mesh files")
    i.add_argument("files", nargs="+")
    i.add_argument("--weld", action="store_true", help="merge identical positions first (STL-like soups)")
    i.add_argument("--write-clean", metavar="OUT.obj", help="write cleaned + consistently oriented mesh")
    i.set_defaults(fn=cmd_info)

    s = sub.add_parser("iso", help="are two meshes isomorphic?")
    s.add_argument("a")
    s.add_argument("b")
    s.add_argument("--geometric", action="store_true", help="compare coordinates+triangles instead of connectivity")
    s.add_argument("--tol", type=float, default=0.0, help="geometric mode: match vertices within this distance (default: exact)")
    s.add_argument("--unoriented", action="store_true", help="geometric mode: ignore triangle orientation")
    s.add_argument("--mirror", action="store_true", help="also accept mirror images (reversed orientation)")
    s.add_argument("--weld", action="store_true", help="merge duplicate positions in both inputs first")
    s.add_argument("--map", metavar="FILE", help="write the vertex correspondence A->B")
    s.add_argument("--general-max-faces", type=int, default=3000)
    s.add_argument("--time-limit", type=float, default=600, help="seconds for the exact search (default 600)")
    s.set_defaults(fn=cmd_iso)

    y = sub.add_parser("synth", help="write synthetic test meshes")
    y.add_argument("--out", default="meshes/synthetic")
    y.add_argument("--format", choices=["obj", "ply"], default="obj")
    y.set_defaults(fn=cmd_synth)

    d = sub.add_parser("subdivide", help="midpoint subdivision for scaling tests")
    d.add_argument("inp")
    d.add_argument("out")
    d.add_argument("--levels", type=int, default=1)
    d.set_defaults(fn=cmd_subdivide)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
