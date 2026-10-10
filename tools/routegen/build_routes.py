#!/usr/bin/env python3
"""
Breakaway route generator.

Builds the bundled route catalogue from real map data:

  * Road geometry  - OpenStreetMap via OSRM (router.project-osrm.org for the
                     car profile, routing.openstreetmap.de for the bike profile).
  * Road elevation - Copernicus EU-DEM 25 m (Europe) or SRTM 30 m elsewhere,
                     via the OpenTopoData public API.
  * Terrain        - A DEM height grid around every route, so the 3D world shows
                     the real valleys and mountains the road passes through.

Every route is validated against the published race figures in routes.json and
a report is written to docs/ROUTES.md. The output is a Swift source file with
compact encoded data so the app ships as a single self-contained binary.

Usage:
    python3 tools/routegen/build_routes.py [--only id1,id2] [--report-only]

Network responses are cached in tools/routegen/.cache so re-runs are free and
the public APIs are only hit once per unique request.

Map data (c) OpenStreetMap contributors, ODbL 1.0. Elevation: Copernicus EU-DEM,
NASA SRTM (public domain).
"""

import argparse
import base64
import hashlib
import json
import math
import os
import struct
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE_DIR = os.path.join(HERE, ".cache")
SPEC_PATH = os.path.join(HERE, "routes.json")
SWIFT_OUT = os.path.join(ROOT, "Sources", "BreakawayCore", "Routes", "RouteCatalog+Generated.swift")
REPORT_OUT = os.path.join(ROOT, "docs", "ROUTES.md")

USER_AGENT = "BreakawayRouteBuilder/1.0 (open-source cycling simulator)"
EARTH_R = 6371008.8

OSRM_CAR = "https://router.project-osrm.org/route/v1/driving/"
OSRM_BIKE = "https://routing.openstreetmap.de/routed-bike/route/v1/driving/"
# The foot profile ignores one-way restrictions, which matters for race circuits
# run on closed roads against normal traffic flow.
OSRM_FOOT = "https://routing.openstreetmap.de/routed-foot/route/v1/driving/"
NOMINATIM = "https://nominatim.openstreetmap.org/search"
TOPO = "https://api.opentopodata.org/v1/eudem25m,srtm30m"

_last_call = {}


# --------------------------------------------------------------------------- #
# HTTP with on-disk cache and polite rate limiting
# --------------------------------------------------------------------------- #

def fetch_json(url, host_key, min_interval=1.1, data=None):
    os.makedirs(CACHE_DIR, exist_ok=True)
    key = hashlib.sha1((url + (data or "")).encode()).hexdigest()
    path = os.path.join(CACHE_DIR, key + ".json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    wait = min_interval - (time.time() - _last_call.get(host_key, 0))
    if wait > 0:
        time.sleep(wait)
    body = data.encode() if data else None
    headers = {"User-Agent": USER_AGENT}
    if body:
        headers["Content-Type"] = "application/json"
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, data=body, headers=headers)
            with urllib.request.urlopen(req, timeout=60) as r:
                payload = json.loads(r.read().decode())
            break
        except Exception as e:  # noqa: BLE001 - retry any transient failure
            if attempt == 4:
                raise
            print(f"    retry {attempt + 1} after error: {e}", file=sys.stderr)
            time.sleep(2 ** (attempt + 1))
    _last_call[host_key] = time.time()
    with open(path, "w") as f:
        json.dump(payload, f)
    return payload


def geocode(query):
    url = NOMINATIM + "?" + urllib.parse.urlencode({"q": query, "format": "json", "limit": 1})
    res = fetch_json(url, "nominatim", min_interval=2.0)
    if not res:
        raise SystemExit(f"Could not geocode '{query}'")
    return float(res[0]["lat"]), float(res[0]["lon"])


def resolve(wp):
    if isinstance(wp, str):
        return geocode(wp)
    return float(wp[0]), float(wp[1])


def bearing_of(wp):
    """Optional third element of a waypoint: required direction of travel in degrees."""
    if isinstance(wp, list) and len(wp) >= 3:
        return f"{int(wp[2]) % 360},{int(wp[3]) if len(wp) > 3 else 45}"
    return ""


# --------------------------------------------------------------------------- #
# Geometry helpers
# --------------------------------------------------------------------------- #

def haversine(a, b):
    la1, lo1 = math.radians(a[0]), math.radians(a[1])
    la2, lo2 = math.radians(b[0]), math.radians(b[1])
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * EARTH_R * math.asin(math.sqrt(h))


def remove_spurs(coords, max_spur_m=3000.0):
    """
    A waypoint that snaps onto a side road makes the router ride out and back on
    the same OSM nodes. Detect revisits of an identical node and cut the spur.
    Returns the trimmed coordinates and the removed intervals as merged
    (start, end) distances along the original track.
    """
    out = list(coords)
    orig_idx = list(range(len(coords)))
    removed_idx = []
    changed = True
    while changed:
        changed = False
        index = {}
        for i, c in enumerate(out):
            key = (round(c[0], 6), round(c[1], 6))
            if key in index:
                j0 = index[key]
                if 0 < j0 and i < len(out) - 1:
                    length = sum(haversine(out[k], out[k + 1]) for k in range(j0, i))
                    if length <= max_spur_m:
                        removed_idx.append((orig_idx[j0], orig_idx[i]))
                        out = out[:j0] + out[i:]
                        orig_idx = orig_idx[:j0] + orig_idx[i:]
                        changed = True
                        break
            index[key] = i
    cum = cumulative(coords)
    merged = []
    for a, b in sorted(removed_idx):
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return out, [(cum[a], cum[b]) for a, b in merged]


def map_distance(d, intervals):
    """Original-track distance -> trimmed-track distance."""
    shift = 0.0
    for a, b in intervals:
        if d >= b:
            shift += b - a
        elif d > a:
            return a - shift
    return d - shift


def densify(coords, max_step):
    """Keep every router vertex (preserves hairpins) and add points on long straights."""
    out = [coords[0]]
    for a, b in zip(coords, coords[1:]):
        d = haversine(a, b)
        n = int(d // max_step)
        for i in range(1, n + 1):
            t = i / (n + 1)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
        out.append(b)
    # Drop exact duplicates which would create zero-length segments.
    dedup = [out[0]]
    for p in out[1:]:
        if haversine(dedup[-1], p) > 0.3:
            dedup.append(p)
    return dedup


def cumulative(coords):
    d = [0.0]
    for a, b in zip(coords, coords[1:]):
        d.append(d[-1] + haversine(a, b))
    return d


def interp(xs, ys, x):
    if x <= xs[0]:
        return ys[0]
    if x >= xs[-1]:
        return ys[-1]
    lo, hi = 0, len(xs) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if xs[mid] <= x:
            lo = mid
        else:
            hi = mid
    t = (x - xs[lo]) / max(xs[hi] - xs[lo], 1e-9)
    return ys[lo] + (ys[hi] - ys[lo]) * t


def gaussian_smooth(dist, values, sigma, loop=False):
    """Distance-aware Gaussian smoothing (handles irregular vertex spacing)."""
    n = len(values)
    total = dist[-1]
    out = []
    j0 = 0
    for i in range(n):
        acc = wsum = 0.0
        while dist[j0] < dist[i] - 3 * sigma:
            j0 += 1
        j = j0
        while j < n and dist[j] <= dist[i] + 3 * sigma:
            w = math.exp(-0.5 * ((dist[j] - dist[i]) / sigma) ** 2)
            acc += w * values[j]
            wsum += w
            j += 1
        if loop:
            # Wrap the kernel across the start/finish line of circuits.
            for jj in range(n):
                dd = dist[jj] + total - dist[i]
                if abs(dd) > 3 * sigma:
                    break
                w = math.exp(-0.5 * (dd / sigma) ** 2)
                acc += w * values[jj]
                wsum += w
            for jj in range(n - 1, -1, -1):
                dd = dist[jj] - total - dist[i]
                if abs(dd) > 3 * sigma:
                    break
                w = math.exp(-0.5 * (dd / sigma) ** 2)
                acc += w * values[jj]
                wsum += w
        out.append(acc / wsum)
    return out


def clamp_grades(dist, elev, max_grade_pct, loop=False):
    """
    DEMs blur steep hillsides, so a road cut into a slope can read a few metres
    high or low and produce impossible spikes on hairpins. Clamp every segment to
    the climb's published maximum, re-integrate, and spread any resulting drift
    linearly so the start and finish elevations stay exactly as measured.
    """
    g = max_grade_pct / 100.0
    out = [elev[0]]
    for i in range(1, len(elev)):
        dd = dist[i] - dist[i - 1]
        de = max(-g * dd, min(g * dd, elev[i] - elev[i - 1]))
        out.append(out[-1] + de)
    target_end = elev[0] if loop else elev[-1]
    drift = target_end - out[-1]
    total = dist[-1] or 1.0
    return [e + drift * (d / total) for e, d in zip(out, dist)]


def project_onto(coords, cum, point, after=0.0):
    """Distance along track of the closest vertex to `point` (searching after `after`)."""
    best, best_d = None, float("inf")
    for c, d in zip(coords, cum):
        if d < after:
            continue
        dd = haversine(c, point)
        if dd < best_d:
            best_d, best = dd, d
    return best, best_d


# --------------------------------------------------------------------------- #
# Data acquisition
# --------------------------------------------------------------------------- #

def route_geometry(spec):
    wps = list(spec["waypoints"])
    if spec.get("loop"):
        wps.append(wps[0])
    pts = [resolve(w) for w in wps]
    router = spec.get("router", "car")
    base = {"bike": OSRM_BIKE, "foot": OSRM_FOOT}.get(router, OSRM_CAR)
    coord_str = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in pts)
    url = base + coord_str + "?overview=full&geometries=geojson&steps=true&continue_straight=false"
    bearings = [bearing_of(w) for w in wps]
    if any(bearings):
        url += "&bearings=" + ";".join(bearings)
    host = "osrm-" + router
    res = fetch_json(url, host, min_interval=1.5)
    if res.get("code") != "Ok":
        raise SystemExit(f"Routing failed for {spec['id']}: {res}")
    route = res["routes"][0]
    coords = [(c[1], c[0]) for c in route["geometry"]["coordinates"]]
    streets, spans, offset = [], [], 0.0
    for leg in route["legs"]:
        for step in leg["steps"]:
            name = step.get("name") or step.get("ref") or ""
            if name and (not streets or streets[-1] != name) and step["distance"] > 60:
                streets.append(name)
            if name:
                spans.append((name, offset, offset + step["distance"]))
            offset += step["distance"]
    # OSRM step distances and our haversine distances differ by a fraction of a
    # percent; rescale so spans line up with the densified track.
    scale = 1.0
    if offset > 0:
        scale = cumulative(coords)[-1] / offset
    spans = [(n, a * scale, b * scale) for n, a, b in spans]
    return coords, streets, pts, spans


def elevations(points):
    out = []
    for i in range(0, len(points), 100):
        chunk = points[i:i + 100]
        locs = "|".join(f"{lat:.5f},{lon:.5f}" for lat, lon in chunk)
        res = fetch_json(TOPO + "?locations=" + locs, "topo", min_interval=1.2)
        if res.get("status") != "OK":
            raise SystemExit(f"Elevation lookup failed: {res}")
        for r in res["results"]:
            e = r["elevation"]
            out.append(0.0 if e is None else max(float(e), 0.0))
    return out


# --------------------------------------------------------------------------- #
# Encoding (Google polyline algorithm, extended with an elevation dimension)
# --------------------------------------------------------------------------- #

def _enc_value(v):
    v = ~(v << 1) if v < 0 else (v << 1)
    s = []
    while v >= 0x20:
        s.append(chr((0x20 | (v & 0x1F)) + 63))
        v >>= 5
    s.append(chr(v + 63))
    return "".join(s)


def encode_track(coords, elev):
    out, plat, plon, pele = [], 0, 0, 0
    for (lat, lon), e in zip(coords, elev):
        ilat, ilon, iele = round(lat * 1e5), round(lon * 1e5), round(e * 10)
        out.append(_enc_value(ilat - plat))
        out.append(_enc_value(ilon - plon))
        out.append(_enc_value(iele - pele))
        plat, plon, pele = ilat, ilon, iele
    return "".join(out)


# --------------------------------------------------------------------------- #
# Main build
# --------------------------------------------------------------------------- #

def terrain_grid(coords, spec):
    lats = [c[0] for c in coords]
    lons = [c[1] for c in coords]
    lat0 = (min(lats) + max(lats)) / 2
    m_per_lat = 111_320.0
    m_per_lon = 111_320.0 * math.cos(math.radians(lat0))
    span_x = (max(lons) - min(lons)) * m_per_lon
    span_y = (max(lats) - min(lats)) * m_per_lat
    margin = max(2500.0, 0.35 * max(span_x, span_y))
    size = max(span_x, span_y) + 2 * margin
    n = spec.get("terrain_grid", 48)
    cx = (min(lons) + max(lons)) / 2
    cy = lat0
    half_deg_lat = (size / 2) / m_per_lat
    half_deg_lon = (size / 2) / m_per_lon
    south, north = cy - half_deg_lat, cy + half_deg_lat
    west, east = cx - half_deg_lon, cx + half_deg_lon
    pts = []
    for j in range(n):
        lat = south + (north - south) * j / (n - 1)
        for i in range(n):
            lon = west + (east - west) * i / (n - 1)
            pts.append((lat, lon))
    hs = elevations(pts)
    raw = b"".join(struct.pack("<h", int(round(h))) for h in hs)
    return {
        "south": south, "west": west, "north": north, "east": east, "n": n,
        "data": base64.b64encode(raw).decode(), "min": min(hs), "max": max(hs),
    }


def build(spec, with_terrain=True):
    print(f"• {spec['id']}: routing…", flush=True)
    raw_coords, streets, resolved, spans = route_geometry(spec)
    trimmed, removed = remove_spurs(raw_coords)
    if removed:
        desc = ", ".join(f"{a / 1000:.2f}–{b / 1000:.2f} km" for a, b in removed)
        print(f"  removed out-and-back spur(s) at {desc}", flush=True)
        spans = [(n, map_distance(a, removed), map_distance(b, removed)) for n, a, b in spans]
        spans = [x for x in spans if x[2] - x[1] > 1]
    coords = densify(trimmed, 25.0)
    cum = cumulative(coords)
    total = cum[-1]

    # Sample the DEM every ~30 m and interpolate onto the (irregular) vertices.
    sample_d = [i * 30.0 for i in range(int(total // 30.0) + 1)] + [total]
    sample_pts = []
    for d in sample_d:
        lat = interp(cum, [c[0] for c in coords], d)
        lon = interp(cum, [c[1] for c in coords], d)
        sample_pts.append((lat, lon))
    print(f"  {len(coords)} vertices, {total / 1000:.2f} km — sampling {len(sample_pts)} elevations…", flush=True)
    sample_e = elevations(sample_pts)
    elev = [interp(sample_d, sample_e, d) for d in cum]
    elev = gaussian_smooth(cum, elev, spec.get("smooth_sigma", 90.0), loop=spec.get("loop", False))
    elev = clamp_grades(cum, elev, spec.get("max_grade", 16.0), loop=spec.get("loop", False))

    gain = sum(max(0.0, b - a) for a, b in zip(elev, elev[1:]))
    # Peak gradient over a 100 m window (what riders and race books quote).
    max_grade = 0.0
    j = 0
    for i in range(len(cum)):
        while j < len(cum) - 1 and cum[j] - cum[i] < 100:
            j += 1
        if cum[j] - cum[i] >= 90:
            max_grade = max(max_grade, (elev[j] - elev[i]) / (cum[j] - cum[i]) * 100)

    segments = []
    for seg in spec.get("segments", []):
        s, sd = project_onto(coords, cum, resolve(seg["from"]))
        e, ed = project_onto(coords, cum, resolve(seg["to"]), after=s)
        if e is None or e <= s:
            print(f"  ! segment {seg['name']} could not be placed", file=sys.stderr)
            continue
        if max(sd, ed) > 400:
            print(f"  ! segment {seg['name']} endpoints {sd:.0f} m / {ed:.0f} m off route", file=sys.stderr)
        segments.append({"name": seg["name"], "kind": seg.get("kind", "climb"), "start": round(s), "end": round(e)})

    def street_ranges(name):
        """Merge consecutive OSRM steps that carry the given street name."""
        out = []
        for n, a, b in spans:
            if n != name:
                continue
            if out and a - out[-1][1] < 30:
                out[-1][1] = b
            else:
                out.append([a, b])
        return out

    for seg in spec.get("street_segments", []):
        for a, b in street_ranges(seg["street"]):
            segments.append({"name": seg["name"], "kind": seg.get("kind", "climb"), "start": round(a), "end": round(b)})

    surfaces = []
    for sec in spec.get("street_surfaces", []):
        ranges = street_ranges(sec["street"])
        if not ranges:
            print(f"  ! street {sec['street']} not on route", file=sys.stderr)
        for a, b in ranges:
            surfaces.append({"surface": sec["surface"], "start": round(a), "end": round(b), "name": sec.get("name", sec["street"])})
    for sec in spec.get("surfaces", []):
        s, _ = project_onto(coords, cum, resolve(sec["from"]))
        e, _ = project_onto(coords, cum, resolve(sec["to"]), after=s)
        if e is not None and e > s:
            surfaces.append({"surface": sec["surface"], "start": round(s), "end": round(e), "name": sec.get("name", "")})

    terrain = None
    if with_terrain:
        print("  terrain grid…", flush=True)
        terrain = terrain_grid(coords, spec)

    official_km = spec.get("official", {}).get("distance_km")
    if official_km:
        quality = "verified" if abs(total / 1000 - official_km) / official_km <= 0.06 else "approximate"
    else:
        quality = "traced"

    return {
        "quality": quality,
        "spec": spec,
        "coords": coords,
        "elev": elev,
        "distance": total,
        "gain": gain,
        "max_grade": max_grade,
        "start_elev": elev[0],
        "top_elev": max(elev),
        "streets": streets,
        "segments": segments,
        "surfaces": surfaces,
        "terrain": terrain,
        "spans": spans,
    }


def swift_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_swift(results):
    lines = [
        "// GENERATED FILE — do not edit by hand.",
        "// Produced by tools/routegen/build_routes.py from OpenStreetMap road geometry",
        "// (© OpenStreetMap contributors, ODbL 1.0) and Copernicus EU-DEM / NASA SRTM elevation.",
        "",
        "extension RouteCatalog {",
        "    static let bundled: [RouteRecord] = [",
    ]
    for r in results:
        s = r["spec"]
        t = r["terrain"]
        seg_items = ", ".join(
            f"RouteRecord.Segment(name: {swift_str(g['name'])}, kind: .{g['kind']}, startMeters: {g['start']}, endMeters: {g['end']})"
            for g in r["segments"]
        )
        surf_items = ", ".join(
            f"RouteRecord.SurfaceSection(surface: .{x['surface']}, startMeters: {x['start']}, endMeters: {x['end']}, name: {swift_str(x['name'])})"
            for x in r["surfaces"]
        )
        official = s.get("official", {})
        off_parts = []
        if "distance_km" in official:
            off_parts.append(f"distanceKm: {official['distance_km']}")
        if "elevation_m" in official:
            off_parts.append(f"elevationGainM: {official['elevation_m']}")
        if "avg_grade" in official:
            off_parts.append(f"averageGradePercent: {official['avg_grade']}")
        official_str = f"RouteRecord.OfficialStats({', '.join(off_parts)})" if off_parts else "nil"
        lines += [
            "        RouteRecord(",
            f"            id: {swift_str(s['id'])},",
            f"            name: {swift_str(s['name'])},",
            f"            category: .{s['category']},",
            f"            event: {swift_str(s['event'])},",
            f"            location: {swift_str(s['location'])},",
            f"            countryCode: {swift_str(s['country'])},",
            f"            summary: {swift_str(s['summary'])},",
            f"            isLoop: {'true' if s.get('loop') else 'false'},",
            f"            defaultLaps: {s.get('laps', 1)},",
            f"            biome: .{s.get('biome', 'alpine')},",
            f"            official: {official_str},",
            f"            quality: .{r['quality']},",
            f"            streets: [{', '.join(swift_str(x) for x in r['streets'][:24])}],",
            f"            segments: [{seg_items}],",
            f"            surfaces: [{surf_items}],",
            f"            climbNames: [{', '.join(swift_str(x) for x in s.get('climb_names', []))}],",
            f"            encodedTrack: {swift_str(encode_track(r['coords'], r['elev']))},",
            "            terrain: RouteRecord.TerrainGrid(",
            f"                south: {t['south']:.6f}, west: {t['west']:.6f}, north: {t['north']:.6f}, east: {t['east']:.6f},",
            f"                resolution: {t['n']},",
            f"                base64Int16: {swift_str(t['data'])}",
            "            )",
            "        ),",
        ]
    lines += ["    ]", "}", ""]
    os.makedirs(os.path.dirname(SWIFT_OUT), exist_ok=True)
    with open(SWIFT_OUT, "w") as f:
        f.write("\n".join(lines))


def pct_diff(a, b):
    return (a - b) / b * 100 if b else 0


def emit_report(results):
    lines = [
        "# Route Catalogue & Data Validation",
        "",
        "Every bundled route is traced over real OpenStreetMap roads and sampled from real",
        "elevation models (Copernicus EU-DEM 25 m in Europe, NASA SRTM 30 m elsewhere).",
        "The table compares the generated route with published race-book figures.",
        "",
        "> Generated by `tools/routegen/build_routes.py` — re-run it to refresh the data.",
        "",
        "**Data quality:** *verified* = traced over the real roads and within 6 % of the official",
        "distance; *approximate* = traced over the named roads of the course but the exact street",
        "sequence could not be confirmed (import the organiser's official GPX for a perfect copy);",
        "*traced* = real roads and elevation, no official distance published for this section.",
        "",
        "| Route | Event | Data | Distance (built) | Distance (official) | Δ | Climbing (built) | Climbing (official) | Max grade (100 m) |",
        "|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for r in results:
        s = r["spec"]
        off = s.get("official", {})
        od = off.get("distance_km")
        oe = off.get("elevation_m")
        dd = f"{pct_diff(r['distance'] / 1000, od):+.1f}%" if od else "—"
        lines.append(
            f"| {s['name']} | {s['event']} | {r['quality']} | {r['distance'] / 1000:.2f} km | {od if od else '—'}{' km' if od else ''} | {dd} | "
            f"{r['gain']:.0f} m | {str(oe) + ' m' if oe else '—'} | {r['max_grade']:.1f}% |"
        )
    lines += ["", "## Roads followed", ""]
    for r in results:
        lines.append(f"**{r['spec']['name']}** — {' → '.join(r['streets'][:24]) or '(unnamed roads)'}")
        lines.append("")
    lines += [
        "## Attribution",
        "",
        "* Road geometry © OpenStreetMap contributors, available under the Open Database License (ODbL 1.0).",
        "* Routing by OSRM (Project OSRM / FOSSGIS routing servers).",
        "* Elevation: Copernicus EU-DEM v1.1 and NASA SRTM, served by OpenTopoData.",
        "",
    ]
    os.makedirs(os.path.dirname(REPORT_OUT), exist_ok=True)
    with open(REPORT_OUT, "w") as f:
        f.write("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma separated route ids to (re)build and print; does not write output")
    args = ap.parse_args()
    with open(SPEC_PATH) as f:
        specs = json.load(f)["routes"]
    if args.only:
        wanted = set(args.only.split(","))
        specs = [s for s in specs if s["id"] in wanted]
    results = []
    for spec in specs:
        r = build(spec, with_terrain=not args.only)
        off = spec.get("official", {})
        print(
            f"  => {r['distance'] / 1000:.2f} km (official {off.get('distance_km', '?')}), "
            f"+{r['gain']:.0f} m (official {off.get('elevation_m', '?')}), "
            f"{r['start_elev']:.0f}→{r['top_elev']:.0f} m, max {r['max_grade']:.1f}%",
            flush=True,
        )
        print(f"     roads: {' → '.join(r['streets'][:30])}")
        for g in r["segments"]:
            length = g["end"] - g["start"]
            rise = interp(cumulative(r["coords"]), r["elev"], g["end"]) - interp(cumulative(r["coords"]), r["elev"], g["start"])
            print(f"     segment {g['name']}: {length / 1000:.2f} km @ {rise / max(length, 1) * 100:.1f}%")
        for x in r["surfaces"]:
            print(f"     surface {x['surface']} {x['name']}: {x['start']}–{x['end']} m")
        if args.only and os.environ.get("SHOW_SPANS"):
            for n, a, b in r["spans"]:
                print(f"       {a:7.0f}–{b:7.0f}  {n}")
        results.append(r)
    if not args.only:
        emit_swift(results)
        emit_report(results)
        print(f"Wrote {SWIFT_OUT}\nWrote {REPORT_OUT}")


if __name__ == "__main__":
    main()
