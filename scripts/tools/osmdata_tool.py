"""Checks on osmdata.openstreetmap.de water polygons (the sea layer's source).

    python3 -I osmdata_tool.py stats ZIP OUT.json
    python3 -I osmdata_tool.py compare NEW.json PREV.json [--planet-date YYYY-MM-DD] [--out RESULT.json]
    python3 -I osmdata_tool.py sanity NEW.json [--out RESULT.json]
    python3 -I osmdata_tool.py clip ZIP OUT.zip --bbox=MINLON,MINLAT,MAXLON,MAXLAT

osmdata rebuilds the water polygons from the OSM coastline every day, but stops updating when
the coastline is broken in a way it cannot repair, and a broken or truncated file would sink or
raise whole coasts. So a new download only replaces the last accepted one when it passes
`compare`: feature count within 2%, vertex count within 5%, total area within 0.1%, same extent
and a data date no older than before. `sanity` is the weaker test for the very first build,
when there is nothing to compare with. Exit status 1 means "do not use this file".

`stats` reads the shapefile straight from the zip: README data date, feature, ring and vertex
counts, extent, and the area on a sinusoidal (equal-area) projection of the sphere. `clip` keeps
the records whose box meets the given box (the file is pre-split into 1-degree cells, so no
geometry is cut) and writes a much smaller zip of the same layout, for local test builds.
"""

import argparse
import hashlib
import io
import json
import re
import struct
import sys
import zipfile

import numpy as np

KM_PER_DEG = 6371.0088 * np.pi / 180  # mean Earth radius
LIMITS = {"features": 0.02, "vertices": 0.05, "area_km2": 0.001}
# Bounds for a first build with nothing to compare with (2026-11-12 data: 53,328 features,
# 79.7 M vertices); generous on purpose, they only catch a truncated or empty file.
SANITY = {"features": (40_000, 70_000), "vertices": (60e6, 110e6), "area_km2": (3.4e8, 3.9e8)}


def _members(zf):
    names = zf.namelist()
    shp = next(n for n in names if n.endswith(".shp"))
    base = shp[:-4]
    return names, base


def data_date(readme):
    m = re.search(r"Date of the data used is (\S+)", readme)
    return m.group(1) if m else None


def cmd_stats(args):
    sha = hashlib.sha256()
    size = 0
    with open(args.zip, "rb") as f:
        while chunk := f.read(16 << 20):
            sha.update(chunk)
            size += len(chunk)
    with zipfile.ZipFile(args.zip) as zf:
        names, base = _members(zf)
        readme_name = next((n for n in names if n.lower().endswith("readme.txt")), None)
        readme = zf.read(readme_name).decode("utf-8", "replace") if readme_name else ""
        features = rings = vertices = 0
        area2 = 0.0  # twice the signed area, km^2
        with zf.open(base + ".shp") as shp:
            head = shp.read(100)
            shape_type = struct.unpack_from("<i", head, 32)[0]
            bbox = list(struct.unpack_from("<4d", head, 36))
            while rec := shp.read(8):
                _, words = struct.unpack(">2i", rec)
                content = shp.read(words * 2)
                stype = struct.unpack_from("<i", content, 0)[0]
                if stype == 0:
                    continue
                if stype != 5:
                    raise SystemExit(f"unexpected shape type {stype}")
                nparts, npoints = struct.unpack_from("<2i", content, 36)
                parts = np.frombuffer(content, "<i4", nparts, 44)
                pts = np.frombuffer(content, "<f8", 2 * npoints, 44 + 4 * nparts).reshape(-1, 2)
                lat = pts[:, 1] * KM_PER_DEG
                lon = pts[:, 0] * KM_PER_DEG * np.cos(np.radians(pts[:, 1]))
                cross = lon[:-1] * lat[1:] - lon[1:] * lat[:-1]
                ends = np.append(parts[1:], npoints) - 1  # last edge index + 1 of each ring
                for a, b in zip(parts, ends):  # shapefile rings are closed; skip the ring-to-ring edge
                    area2 += cross[a:b].sum()
                features += 1
                rings += nparts
                vertices += npoints
    out = {"file": args.zip.rsplit("/", 1)[-1], "bytes": size, "sha256": sha.hexdigest(),
           "data_date": data_date(readme), "shape_type": shape_type, "features": features,
           "rings": rings, "vertices": vertices,
           # outer rings run clockwise in shapefiles, so the signed sum is negative
           "area_km2": round(-area2 / 2, 1) + 0.0, "bbox": [round(v, 6) for v in bbox]}
    with open(args.out, "w") as f:
        json.dump(out, f, indent=1)
    print(json.dumps(out))


def _write(result, path):
    if path:
        with open(path, "w") as f:
            json.dump(result, f, indent=1)
    print(json.dumps(result))
    return 0 if result["ok"] else 1


def cmd_compare(args):
    with open(args.new) as f:
        new = json.load(f)
    with open(args.prev) as f:
        prev = json.load(f)
    checks, warnings, ok = {}, [], True
    for key, limit in LIMITS.items():
        if prev.get(key) is None:
            warnings.append(f"previous stats lack {key}; not compared")
            continue
        change = new[key] / prev[key] - 1
        passed = abs(change) <= limit
        checks[key] = {"previous": prev[key], "new": new[key], "change": round(change, 6), "limit": limit, "ok": passed}
        ok &= passed
    if prev.get("bbox"):
        passed = all(abs(a - b) <= 0.01 for a, b in zip(new["bbox"], prev["bbox"]))
        checks["bbox"] = {"previous": prev["bbox"], "new": new["bbox"], "ok": passed}
        ok &= passed
    if new.get("data_date") and prev.get("data_date"):
        passed = new["data_date"] >= prev["data_date"]
        checks["data_date"] = {"previous": prev["data_date"], "new": new["data_date"], "ok": passed}
        ok &= passed
        if new["data_date"] == prev["data_date"]:
            warnings.append("data date unchanged since the previous build: osmdata may have stopped updating")
    else:
        ok = False
        checks["data_date"] = {"new": new.get("data_date"), "ok": False}
    if args.planet_date and new.get("data_date"):
        lag = (np.datetime64(args.planet_date[:10]) - np.datetime64(new["data_date"][:10])).astype(int)
        if lag > 14:
            warnings.append(f"water polygons are {lag} days older than the OSM data")
    return _write({"ok": bool(ok), "checks": checks, "warnings": warnings}, args.out)


def cmd_sanity(args):
    with open(args.new) as f:
        new = json.load(f)
    checks = {k: {"value": new[k], "range": list(r), "ok": r[0] <= new[k] <= r[1]} for k, r in SANITY.items()}
    checks["data_date"] = {"value": new.get("data_date"), "ok": bool(new.get("data_date"))}
    return _write({"ok": all(c["ok"] for c in checks.values()), "checks": checks, "warnings": []}, args.out)


def cmd_clip(args):
    w, s, e, n = (float(v) for v in args.bbox.split(","))
    with zipfile.ZipFile(args.zip) as zf:
        names, base = _members(zf)
        shp = zf.read(base + ".shp")
        dbf = zf.read(base + ".dbf")
        head = bytearray(shp[:100])
        pos, num = 100, 0
        kept, boxes = [], []
        dbf_head_len, dbf_rec_len = struct.unpack_from("<2H", dbf, 8)
        while pos < len(shp):
            _, words = struct.unpack_from(">2i", shp, pos)
            content = shp[pos + 8:pos + 8 + words * 2]
            pos += 8 + words * 2
            num += 1
            if struct.unpack_from("<i", content, 0)[0] == 0:
                continue
            x0, y0, x1, y1 = struct.unpack_from("<4d", content, 4)
            if x1 < w or x0 > e or y1 < s or y0 > n:
                continue
            kept.append((num, content))
            boxes.append((x0, y0, x1, y1))
        shp_out, shx_out = io.BytesIO(), io.BytesIO()
        offset = 50  # words
        shx_body = io.BytesIO()
        body = io.BytesIO()
        for i, (_, content) in enumerate(kept, 1):
            body.write(struct.pack(">2i", i, len(content) // 2) + content)
            shx_body.write(struct.pack(">2i", offset, len(content) // 2))
            offset += 4 + len(content) // 2
        if boxes:
            struct.pack_into("<4d", head, 36, min(b[0] for b in boxes), min(b[1] for b in boxes),
                             max(b[2] for b in boxes), max(b[3] for b in boxes))
        shx_head = bytearray(head)
        struct.pack_into(">i", head, 24, 50 + len(body.getvalue()) // 2)
        struct.pack_into(">i", shx_head, 24, 50 + 4 * len(kept))
        shp_out.write(head + body.getvalue())
        shx_out.write(shx_head + shx_body.getvalue())
        dbf_out = bytearray(dbf[:dbf_head_len])
        struct.pack_into("<I", dbf_out, 4, len(kept))
        for rec, _ in kept:
            start = dbf_head_len + (rec - 1) * dbf_rec_len
            dbf_out += dbf[start:start + dbf_rec_len]
        dbf_out += b"\x1a"
        with zipfile.ZipFile(args.out, "w", zipfile.ZIP_DEFLATED) as out:
            out.writestr(base + ".shp", shp_out.getvalue())
            out.writestr(base + ".shx", shx_out.getvalue())
            out.writestr(base + ".dbf", bytes(dbf_out))
            for name in names:
                if name.endswith((".prj", ".cpg")):
                    out.writestr(name, zf.read(name))
                elif name.lower().endswith("readme.txt"):
                    note = (f"\n\nSUBSET (meshwish osmdata_tool.py clip): {len(kept)} of {num} records whose box"
                            f" meets {w},{s},{e},{n}; records are unchanged.\n")
                    out.writestr(name, zf.read(name) + note.encode())
    print(json.dumps({"kept": len(kept), "of": num, "bbox": [w, s, e, n], "out": args.out}))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("stats")
    p.add_argument("zip")
    p.add_argument("out")
    p = sub.add_parser("compare")
    p.add_argument("new")
    p.add_argument("prev")
    p.add_argument("--planet-date")
    p.add_argument("--out")
    p = sub.add_parser("sanity")
    p.add_argument("new")
    p.add_argument("--out")
    p = sub.add_parser("clip")
    p.add_argument("zip")
    p.add_argument("out")
    p.add_argument("--bbox", required=True, help="W,S,E,N; write --bbox=... when W is negative")
    args = ap.parse_args()
    return {"stats": cmd_stats, "compare": cmd_compare, "sanity": cmd_sanity, "clip": cmd_clip}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main() or 0)
