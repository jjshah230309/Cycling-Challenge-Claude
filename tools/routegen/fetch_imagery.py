#!/usr/bin/env python3
"""
Satellite imagery for the 3D terrain.

For every route in the generated catalogue, downloads Sentinel-2 cloudless
(2016 edition, CC BY 4.0) web-mercator tiles covering the route's terrain grid,
reprojects them onto the grid's latitude/longitude box (which maps linearly onto
the app's local east/north metres) and writes a JPEG the app drapes over the
terrain:

    Sources/Breakaway/Resources/Imagery/<route-id>.jpg

Usage:  python3 tools/routegen/fetch_imagery.py [--only id1,id2] [--size 2048]

Imagery: "Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH
(Contains modified Copernicus Sentinel data 2016)", CC BY 4.0.
Tiles are cached in tools/routegen/.cache/tiles so re-runs are free.
"""
import argparse
import io
import math
import os
import re
import sys
import time
import urllib.request

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CATALOG = os.path.join(ROOT, "Sources", "BreakawayCore", "Routes", "RouteCatalog+Generated.swift")
OUT_DIR = os.path.join(ROOT, "Sources", "Breakaway", "Resources", "Imagery")
CACHE = os.path.join(HERE, ".cache", "tiles")
TILE_URL = "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/{z}/{y}/{x}.jpg"
USER_AGENT = "BreakawayImagery/1.0 (open-source cycling simulator)"
ZOOM = 14


def routes():
    src = open(CATALOG, encoding="utf-8").read()
    ids = re.findall(r'\bid: "([a-z0-9-]+)"', src)
    boxes = re.findall(r"south: ([\d.-]+), west: ([\d.-]+), north: ([\d.-]+), east: ([\d.-]+)", src)
    if len(ids) != len(boxes):
        sys.exit("could not match route ids to terrain boxes")
    return [(i, tuple(map(float, b))) for i, b in zip(ids, boxes)]


def tile(z, x, y):
    path = os.path.join(CACHE, str(z), str(x), f"{y}.jpg")
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        req = urllib.request.Request(TILE_URL.format(z=z, x=x, y=y), headers={"User-Agent": USER_AGENT})
        for attempt in range(4):
            try:
                data = urllib.request.urlopen(req, timeout=30).read()
                break
            except Exception:
                if attempt == 3:
                    raise
                time.sleep(2 ** attempt)
        with open(path, "wb") as f:
            f.write(data)
    return Image.open(path).convert("RGB")


def merc(lat, lon, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def build(rid, box, size):
    south, west, north, east = box
    x0, y0 = merc(north, west, ZOOM)
    x1, y1 = merc(south, east, ZOOM)
    tx0, ty0, tx1, ty1 = int(x0), int(y0), int(x1), int(y1)
    mosaic = Image.new("RGB", ((tx1 - tx0 + 1) * 256, (ty1 - ty0 + 1) * 256))
    for tx in range(tx0, tx1 + 1):
        for ty in range(ty0, ty1 + 1):
            mosaic.paste(tile(ZOOM, tx, ty), ((tx - tx0) * 256, (ty - ty0) * 256))
    src = np.asarray(mosaic).astype(np.float32)
    # Output pixel (i, j): column i runs west→east, row j north→south, linear in lon/lat.
    lons = west + (np.arange(size) + 0.5) / size * (east - west)
    lats = north - (np.arange(size) + 0.5) / size * (north - south)
    mx = ((lons + 180) / 360 * 2 ** ZOOM - tx0) * 256
    my = ((1 - np.arcsinh(np.tan(np.radians(lats))) / np.pi) / 2 * 2 ** ZOOM - ty0) * 256
    X, Y = np.meshgrid(mx, my)
    xi = np.clip(X.astype(int), 0, src.shape[1] - 2)
    yi = np.clip(Y.astype(int), 0, src.shape[0] - 2)
    fx = np.clip(X - xi, 0, 1)[..., None]
    fy = np.clip(Y - yi, 0, 1)[..., None]
    a = src[yi, xi] * (1 - fx) + src[yi, xi + 1] * fx
    b = src[yi + 1, xi] * (1 - fx) + src[yi + 1, xi + 1] * fx
    out = a * (1 - fy) + b * fy
    # Sentinel-2 cloudless is mastered dark; lift the mid-tones a little for a sunlit look.
    out = 255 * np.power(np.clip(out / 255, 0, 1), 0.82) * 1.04
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, f"{rid}.jpg")
    img.save(path, quality=80, optimize=True, progressive=True)
    return path, (tx1 - tx0 + 1) * (ty1 - ty0 + 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only")
    ap.add_argument("--size", type=int, default=0, help="output pixels (default: ~6 m/px, 1024–2048)")
    args = ap.parse_args()
    only = set(args.only.split(",")) if args.only else None
    for rid, box in routes():
        if only and rid not in only:
            continue
        south, west, north, east = box
        width_m = (east - west) * 111_320 * math.cos(math.radians((south + north) / 2))
        size = args.size or int(min(2048, max(1024, 2 ** round(math.log2(width_m / 6)))))
        path, n = build(rid, box, size)
        print(f"{rid}: {size}px ({width_m / size:.1f} m/px) from {n} tiles → {os.path.relpath(path, ROOT)} "
              f"({os.path.getsize(path) // 1024} KB)", flush=True)


if __name__ == "__main__":
    main()
