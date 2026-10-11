#!/usr/bin/env python3
"""
Realistic rider body for Breakaway.

Builds a lean, athletic adult body from the MakeHuman base mesh and macro
targets (CC0 1.0, https://github.com/makehumancommunity/makehuman), collapses
MakeHuman's 163-bone skin weights onto the 14 bones Breakaway's pose solver
drives (torso, head, upper arm, forearm, hand, thigh, shin, foot), removes the
hands and feet (the game swaps in gripping gloves and cycling shoes), assigns
kit regions (jersey, sleeves, bib shorts, socks, skin, hair) with texture
coordinates matching the procedural kit textures, and writes a compact
quantised blob into

    Sources/BreakawayCore/Models/RiderBody+Generated.swift

Usage:  python3 tools/riderbody/build_rider_body.py
Downloads are cached in tools/riderbody/.cache.
"""
import base64
import json
import math
import os
import struct
import urllib.request

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(HERE, ".cache")
OUT = os.path.join(ROOT, "Sources", "BreakawayCore", "Models", "RiderBody+Generated.swift")
MH = "https://raw.githubusercontent.com/makehumancommunity/makehuman/master/makehuman/data/"
HEIGHT = 1.78

# Body shape: young adult male, a third of each ethnic macro target (MakeHuman's
# default mix), with an athletic low-fat build.
TARGETS = [
    ("targets/macrodetails/caucasian-male-young.target", 1 / 3),
    ("targets/macrodetails/african-male-young.target", 1 / 3),
    ("targets/macrodetails/asian-male-young.target", 1 / 3),
    ("targets/macrodetails/universal-male-young-maxmuscle-minweight.target", 0.55),
]

# Breakaway bones, in RiderBone.allCases order.
BONES = ["torso", "head", "upperArmL", "upperArmR", "forearmL", "forearmR", "handL", "handR",
         "thighL", "thighR", "shinL", "shinR", "footL", "footR"]


def fetch(path):
    local = os.path.join(CACHE, path.replace("/", "_"))
    if not os.path.exists(local):
        os.makedirs(CACHE, exist_ok=True)
        req = urllib.request.Request(MH + path, headers={"User-Agent": "BreakawayRiderBody/1.0"})
        with open(local, "wb") as f:
            f.write(urllib.request.urlopen(req, timeout=60).read())
    return local


def mh_to_breakaway(bone):
    """Fractions of a MakeHuman bone's influence given to Breakaway bones."""
    side = "L" if bone.endswith(".L") else ("R" if bone.endswith(".R") else "")
    # MakeHuman's .L is the character's left.
    s = side
    b = bone[:-2] if side else bone
    if b in ("upperarm01", "upperarm02"):
        return {f"upperArm{s}": 1}
    if b in ("lowerarm01", "lowerarm02"):
        return {f"forearm{s}": 1}
    if b == "wrist" or b.startswith("metacarpal") or b.startswith("finger"):
        return {f"hand{s}": 1}
    if b in ("upperleg01", "upperleg02"):
        return {f"thigh{s}": 1}
    if b in ("lowerleg01", "lowerleg02"):
        return {f"shin{s}": 1}
    if b == "foot" or b.startswith("toe"):
        return {f"foot{s}": 1}
    if b == "shoulder01":
        return {"torso": 0.45, f"upperArm{s}": 0.55}
    if b == "pelvis":
        return {"torso": 0.75, f"thigh{s}": 0.25}
    if b in ("root", "spine01", "spine02", "spine03", "spine04", "spine05", "clavicle", "breast"):
        return {"torso": 1}
    if b == "neck01":
        return {"torso": 0.45, "head": 0.55}
    return {"head": 1}          # neck02/03, head, jaw, eyes and facial muscles


def main():
    # --- Mesh ---
    V, VT, faces = [], [], []
    group = None
    for line in open(fetch("3dobjs/base.obj")):
        if line.startswith("v "):
            V.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("vt "):
            VT.append([float(x) for x in line.split()[1:3]])
        elif line.startswith("g "):
            group = line.split()[1]
        elif line.startswith("f ") and group == "body":
            faces.append([int(t.split("/")[0]) - 1 for t in line.split()[1:]])
    V = np.array(V, dtype=np.float64)
    for path, weight in TARGETS:
        for line in open(fetch(path)):
            if line[0].isdigit():
                i, dx, dy, dz = line.split()
                V[int(i)] += weight * np.array([float(dx), float(dy), float(dz)])

    # --- Skeleton joints (mean of each joint's vertex group) ---
    skel = json.load(open(fetch("rigs/default.mhskel")))
    joints = {name: V[idx].mean(axis=0) for name, idx in skel["joints"].items()}
    head_of = lambda b: joints[skel["bones"][b]["head"]]
    tail_of = lambda b: joints[skel["bones"][b]["tail"]]

    # MakeHuman: decimetres, Y up, facing +Z, character's left = +X.
    # Breakaway body space: metres, Y up, facing −Z, character's right = +X (rotate 180° about Y).
    body_idx = sorted({i for f in faces for i in f})
    floor = V[body_idx, 1].min()
    height = V[body_idx, 1].max() - floor
    scale = HEIGHT / height
    def conv(p):
        return np.array([-p[0], p[1] - floor, -p[2]]) * scale
    P = np.array([conv(p) for p in V])
    J = {
        "hipL": conv(head_of("upperleg01.L")), "hipR": conv(head_of("upperleg01.R")),
        "kneeL": conv(head_of("lowerleg01.L")), "kneeR": conv(head_of("lowerleg01.R")),
        "ankleL": conv(head_of("foot.L")), "ankleR": conv(head_of("foot.R")),
        "shoulderL": conv(head_of("upperarm01.L")), "shoulderR": conv(head_of("upperarm01.R")),
        "elbowL": conv(head_of("lowerarm01.L")), "elbowR": conv(head_of("lowerarm01.R")),
        "wristL": conv(head_of("wrist.L")), "wristR": conv(head_of("wrist.R")),
        "neck": conv(head_of("neck01")), "headTop": conv(tail_of("head")),
    }
    J["hipCentre"] = (J["hipL"] + J["hipR"]) / 2

    # --- Weights ---
    mhw = json.load(open(fetch("rigs/default_weights.mhw")))["weights"]
    W = np.zeros((len(V), len(BONES)))
    for mb, pairs in mhw.items():
        for target, frac in mh_to_breakaway(mb).items():
            k = BONES.index(target)
            for vi, w in pairs:
                W[vi, k] += w * frac
    sums = W.sum(axis=1, keepdims=True)
    W = np.divide(W, sums, out=np.zeros_like(W), where=sums > 0)

    # Drop hands and feet (gloves and shoes replace them) and anything unweighted.
    hand = W[:, BONES.index("handL")] + W[:, BONES.index("handR")]
    foot = W[:, BONES.index("footL")] + W[:, BONES.index("footR")]
    keep = (hand < 0.5) & (foot < 0.5) & (sums[:, 0] > 0)
    tris = []
    for f in faces:
        if all(keep[i] for i in f):
            tris.append((f[0], f[1], f[2]))
            if len(f) == 4:
                tris.append((f[0], f[2], f[3]))
    # --- Rest-pose bone frames (same construction as RigidTransform.bone in Swift) ---
    def bone(a, b, side=np.array([1.0, 0, 0])):
        y = (b - a) / np.linalg.norm(b - a)
        x = side - y * side.dot(y)
        x /= np.linalg.norm(x)
        z = np.cross(x, y)
        return a, np.stack([x, y, z])
    frames = {
        "torso": bone(J["hipCentre"], J["neck"]),
        "upperArmL": bone(J["shoulderL"], J["elbowL"]), "upperArmR": bone(J["shoulderR"], J["elbowR"]),
        "forearmL": bone(J["elbowL"], J["wristL"]), "forearmR": bone(J["elbowR"], J["wristR"]),
        "thighL": bone(J["hipL"], J["kneeL"]), "thighR": bone(J["hipR"], J["kneeR"]),
        "shinL": bone(J["kneeL"], J["ankleL"]), "shinR": bone(J["kneeR"], J["ankleR"]),
        "head": (J["neck"], np.eye(3)),
    }
    def local(name, p):
        o, axes = frames[name]
        return axes.dot(p - o)

    # --- Kit regions ---
    # Kit edges (jersey hem, sleeve cuffs, short legs, sock tops, hairline) are iso-lines of
    # smooth scalar fields. Triangles straddling an edge are split exactly on it, so the
    # boundaries are clean lines rather than a zig-zag of whole triangles.
    torso_len = np.linalg.norm(J["neck"] - J["hipCentre"])
    thigh_len = np.linalg.norm(J["kneeL"] - J["hipL"])
    shin_len = np.linalg.norm(J["ankleL"] - J["kneeL"])
    dominant = W.argmax(axis=1)

    pos = [P[i].copy() for i in range(len(P))]
    wts = [W[i].copy() for i in range(len(P))]
    def field(name, i_or_p):
        p = pos[i_or_p] if isinstance(i_or_p, (int, np.integer)) else i_or_p
        if name == "waist":
            return local("torso", p)[1] - 0.1 * torso_len
        if name.startswith("cuff"):
            return local("upperArm" + name[-1], p)[1] - 0.16
        if name.startswith("leg"):
            return local("thigh" + name[-1], p)[1] - 0.84 * thigh_len
        if name.startswith("sock"):
            return local("shin" + name[-1], p)[1] - (shin_len - 0.13)
        if name == "hair":
            q = local("head", p)
            return max(q[1] - 0.13 + min(0, q[2] + 0.02) * 4, q[1] - 0.2)
        raise ValueError(name)
    def group_of(i):
        b = BONES[int(np.argmax(wts[i]))]
        return b
    fields = [("waist", {"torso"}), ("cuffL", {"upperArmL"}), ("cuffR", {"upperArmR"}),
              ("legL", {"thighL"}), ("legR", {"thighR"}), ("sockL", {"shinL"}), ("sockR", {"shinR"}), ("hair", {"head"})]
    edge_cache = {}
    def split_vertex(i, j, name):
        key = (min(i, j), max(i, j), name)
        if key in edge_cache:
            return edge_cache[key]
        fi, fj = field(name, i), field(name, j)
        t = fi / (fi - fj)
        pos.append(pos[i] + (pos[j] - pos[i]) * t)
        w = wts[i] + (wts[j] - wts[i]) * t
        wts.append(w / w.sum())
        edge_cache[key] = len(pos) - 1
        return edge_cache[key]
    for name, bones_in in fields:
        out = []
        for t in tris:
            if not any(group_of(i) in bones_in for i in t):
                out.append(t)
                continue
            f = [field(name, i) for i in t]
            sides = [v > 0 for v in f]
            if all(sides) or not any(sides) or any(abs(v) < 1e-9 for v in f):
                out.append(t)
                continue
            # One corner is alone on its side: cut the two edges leaving it.
            k = [m for m in range(3) if sides.count(sides[m]) == 1][0]
            a, b, c = t[k], t[(k + 1) % 3], t[(k + 2) % 3]
            ab, ac = split_vertex(a, b, name), split_vertex(a, c, name)
            out += [(a, ab, ac), (ab, b, c), (ab, c, ac)]
        tris = out
    P = np.array(pos)
    W = np.array(wts)
    dominant = W.argmax(axis=1)

    def region_of_triangle(t):
        c = P[list(t)].mean(axis=0)
        b = BONES[int(np.argmax(W[list(t)].sum(axis=0)))]
        if b == "torso":
            return "jersey" if field("waist", c) > 0 else "shorts"
        if b.startswith("upperArm"):
            return "sleeve" if field("cuff" + b[-1], c) < 0 else "skin"
        if b.startswith("thigh"):
            return "shorts" if field("leg" + b[-1], c) < 0 else "skin"
        if b.startswith("shin"):
            return "sock" if field("sock" + b[-1], c) > 0 else "skin"
        if b == "head":
            return "hair" if field("hair", c) > 0 else "skin"
        return "skin"

    def uv_for(i, r):
        p = P[i]
        if r == "jersey" or r == "shorts":
            q = local("torso", p)
            a = math.atan2(q[2], -q[0]) % (2 * math.pi)
            return (a / (2 * math.pi), (q[1] + 0.15 * torso_len) / (1.2 * torso_len))
        if r == "sleeve":
            b = "upperArmL" if p[0] < 0 else "upperArmR"
            q = local(b, p)
            return ((math.atan2(q[2], q[0]) % (2 * math.pi)) / (2 * math.pi), q[1] + 0.03)
        return (0.5, 0.5)

    order = ["jersey", "sleeve", "shorts", "sock", "skin", "hair"]
    groups = {r: [] for r in order}
    for t in tris:
        groups[region_of_triangle(t)].append(t)

    # Vertices are duplicated per region (crisp kit edges) and across the jersey's u seam.
    out_pos, out_nrm, out_uv, out_bi, out_bw = [], [], [], [], []
    vmap = {}
    # Smooth normals over the whole kept body (cut vertices included).
    N = np.zeros_like(P)
    for t in tris:
        n = np.cross(P[t[1]] - P[t[0]], P[t[2]] - P[t[0]])
        for i in t:
            N[i] += n
    N /= np.maximum(np.linalg.norm(N, axis=1, keepdims=True), 1e-12)
    def emit(i, r, u_shift):
        key = (i, r, u_shift)
        if key in vmap:
            return vmap[key]
        u, v = uv_for(i, r)
        out_pos.append(P[i]); out_nrm.append(N[i]); out_uv.append((u + u_shift, v))
        top = np.argsort(-W[i])[:3]
        w = W[i, top]
        w = w / w.sum()
        out_bi.append(top); out_bw.append(w)
        vmap[key] = len(out_pos) - 1
        return vmap[key]
    index_groups = []
    for r in order:
        idx = []
        for t in groups[r]:
            shift = [0, 0, 0]
            if r in ("jersey", "sleeve", "shorts"):
                us = [uv_for(i, r)[0] for i in t]
                if max(us) - min(us) > 0.5:
                    shift = [1 if u < 0.5 else 0 for u in us]
            # MakeHuman winds counter-clockwise; the X mirror flips handedness.
            a2, b2, c2 = (emit(t[k], r, shift[k]) for k in range(3))
            idx += [a2, c2, b2]
        index_groups.append((r, idx))
    n = len(out_pos)
    assert n < 65536, n

    # --- Pack ---
    blob = bytearray(b"BRB1")
    blob += struct.pack("<I", n)
    pos = np.array(out_pos)
    blob += np.clip(np.round(pos * 8000), -32767, 32767).astype("<i2").tobytes()
    blob += np.clip(np.round(np.array(out_nrm) * 127), -127, 127).astype("i1").tobytes()
    uvs = np.array(out_uv)
    blob += np.clip(np.round(uvs * 16000), -32767, 32767).astype("<i2").tobytes()
    blob += np.array(out_bi).astype("u1").tobytes()
    blob += np.clip(np.round(np.array(out_bw) * 255), 0, 255).astype("u1").tobytes()
    for r, idx in index_groups:
        blob += struct.pack("<I", len(idx))
        blob += np.array(idx).astype("<u2").tobytes()
    b64 = base64.b64encode(bytes(blob)).decode()

    used = sorted({i for t in tris for i in t if i < len(keep)})
    # Head size for fitting the helmet: the skull above the jaw.
    head_pts = np.array([local("head", P[i]) for i in used if BONES[dominant[i]] == "head"])
    skull = head_pts[head_pts[:, 1] > 0.07]
    centre = (skull.max(0) + skull.min(0)) / 2
    radii = (skull.max(0) - skull.min(0)) / 2
    # Buttocks below the hip joint (sitting depth).
    pelvis = np.array([P[i] for i in used if BONES[dominant[i]] == "torso"
                       and abs(P[i][0]) < 0.12 and P[i][2] > J["hipCentre"][2]])
    seat_drop = J["hipCentre"][1] - pelvis[:, 1].min()

    def v3(p):
        return f"SIMD3<Float>({p[0]:.5f}, {p[1]:.5f}, {p[2]:.5f})"
    lines = [
        "// Generated by tools/riderbody/build_rider_body.py — do not edit.",
        "// Body mesh, skin weights and skeleton derived from the MakeHuman base mesh and targets",
        "// (CC0 1.0, https://github.com/makehumancommunity/makehuman).",
        "",
        "extension RiderBody {",
        f"    static let materialOrder = {json.dumps(order)}",
        "    static let joints: [String: SIMD3<Float>] = [",
    ]
    for k in sorted(J):
        lines.append(f'        "{k}": {v3(J[k])},')
    lines += [
        "    ]",
        f"    static let skullCentre = {v3(centre)}",
        f"    static let skullRadii = {v3(radii)}",
        f"    static let seatDrop: Float = {seat_drop:.4f}",
        "    static let encoded = \"\"\"",
    ]
    for k in range(0, len(b64), 120):
        lines.append(b64[k:k + 120])
    lines += ["\"\"\"", "}", ""]
    with open(OUT, "w") as f:
        f.write("\n".join(lines))
    print(f"vertices {n}, triangles {sum(len(i) for _, i in index_groups) // 3}, blob {len(blob) // 1024} KB, "
          f"torso {torso_len:.3f} thigh {thigh_len:.3f} shin {shin_len:.3f} seat {seat_drop:.3f}")
    print({r: len(i) // 3 for r, i in index_groups})


if __name__ == "__main__":
    main()
