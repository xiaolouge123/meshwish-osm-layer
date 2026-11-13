"""Read, check and annotate the PMTiles archive a build produced (standard library only).

    python3 -I pmtiles_tool.py info FILE
    python3 -I pmtiles_tool.py set-metadata IN OUT KEY=JSON [KEY=JSON ...]
    python3 -I pmtiles_tool.py verify FILE --out STATS.json [--layerstats TSV.gz]
        [--checkpoints JSON] [--require-layers a,b] [--prev-manifest JSON] [--decode-all]

`set-metadata` rewrites the JSON metadata section and shifts the later sections; directories
and tile bytes are copied unchanged. planetiler's custom-map profiles cannot add metadata keys
of their own, so this is how build.sh adds meshwish_schema, planet_date and the rest.

`verify` is the gate before an upload. It checks the header (PMTiles v3, gzip MVT, z5-14), that
the metadata carries the keys readers depend on, per-layer feature counts (from planetiler's
--output_layerstats file, so it costs nothing on a planet build), feature ids (osm_id * 10 +
1/2/3 and 0 for ocean) in a sample of tiles, and named checkpoints: known places whose tile must
hold a given feature, e.g. a sea point inside the ocean layer or the Matterhorn in the peak
layer. Checkpoints outside the archive's bounds are skipped. With --prev-manifest it compares
per-layer counts with the previous build and fails on a large drop. Exits 1 when a check fails;
the JSON report is written either way.

Tile reading follows the PMTiles v3 spec: a 127-byte header, a root directory (and leaf
directories) of run-length entries keyed by Hilbert tile id, gzip-compressed. MVT is decoded
just far enough for the checks: layer names, feature ids, attributes and geometry commands.
"""

import argparse
import gzip
import hashlib
import json
import math
import re
import struct
import sys
from collections import Counter, defaultdict

HEADER_LEN = 127
COMPRESSION = {0: "unknown", 1: "none", 2: "gzip", 3: "brotli", 4: "zstd"}
TILE_TYPE = {0: "unknown", 1: "mvt", 2: "png", 3: "jpeg", 4: "webp", 5: "avif", 6: "mlt"}
# Metadata keys build.sh adds and readers check; see schema/meshwish-osm.yml.
REQUIRED_METADATA = ("meshwish_schema", "planet_date", "osmdata_date", "build_id", "attribution", "license")
CONTRACT_LAYERS = ("water", "glacier", "waterway", "path", "road", "peak", "ocean")
EARTH_CIRCUMFERENCE_M = 2 * math.pi * 6378137.0


# --- PMTiles container ---------------------------------------------------------------------

def read_header(buf):
    if len(buf) < HEADER_LEN or buf[:7] != b"PMTiles" or buf[7] != 3:
        raise ValueError("not a PMTiles v3 archive")
    q = struct.unpack_from("<11Q", buf, 8)
    h = dict(zip(("root_offset", "root_length", "metadata_offset", "metadata_length", "leaf_offset",
                  "leaf_length", "data_offset", "data_length", "addressed_tiles", "tile_entries",
                  "tile_contents"), q))
    clustered, internal, tile_comp, tile_type, minz, maxz = struct.unpack_from("<6B", buf, 96)
    min_lon, min_lat, max_lon, max_lat = struct.unpack_from("<4i", buf, 102)
    center_z = buf[118]
    center_lon, center_lat = struct.unpack_from("<2i", buf, 119)
    h.update(clustered=bool(clustered), internal_compression=COMPRESSION.get(internal, internal),
             tile_compression=COMPRESSION.get(tile_comp, tile_comp), tile_type=TILE_TYPE.get(tile_type, tile_type),
             min_zoom=minz, max_zoom=maxz, bounds=[min_lon / 1e7, min_lat / 1e7, max_lon / 1e7, max_lat / 1e7],
             center=[center_lon / 1e7, center_lat / 1e7, center_z])
    return h


def decompress(data, kind):
    if kind == "gzip":
        return gzip.decompress(data)
    if kind == "none":
        return data
    raise ValueError(f"unsupported compression {kind}")


def read_varint(buf, pos):
    result = shift = 0
    while True:
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if b < 0x80:
            return result, pos
        shift += 7


def parse_directory(buf):
    """Entries (tile_id, offset, length, run_length); run_length 0 marks a leaf directory."""
    n, pos = read_varint(buf, 0)
    ids, runs, lengths, offsets = [], [], [], []
    last = 0
    for _ in range(n):
        delta, pos = read_varint(buf, pos)
        last += delta
        ids.append(last)
    for _ in range(n):
        v, pos = read_varint(buf, pos)
        runs.append(v)
    for _ in range(n):
        v, pos = read_varint(buf, pos)
        lengths.append(v)
    for i in range(n):
        v, pos = read_varint(buf, pos)
        offsets.append(offsets[i - 1] + lengths[i - 1] if v == 0 and i > 0 else v - 1)
    return list(zip(ids, offsets, lengths, runs))


def zxy_to_tileid(z, x, y):
    """Hilbert tile id: all tiles of lower zooms first, then the Hilbert index within zoom z."""
    acc = ((1 << (2 * z)) - 1) // 3
    n = 1 << z
    d = 0
    s = n >> 1
    while s > 0:
        rx = 1 if x & s else 0
        ry = 1 if y & s else 0
        d += s * s * ((3 * rx) ^ ry)
        if ry == 0:
            if rx == 1:
                x, y = n - 1 - x, n - 1 - y
            x, y = y, x
        s >>= 1
    return acc + d


def tileid_zoom(tile_id):
    z = 0
    while ((1 << (2 * (z + 1))) - 1) // 3 <= tile_id:
        z += 1
    return z


def tileid_to_zxy(tile_id):
    z = tileid_zoom(tile_id)
    t = tile_id - ((1 << (2 * z)) - 1) // 3
    x = y = 0
    s = 1
    while s < (1 << z):
        rx = 1 & (t // 2)
        ry = 1 & (t ^ rx)
        if ry == 0:
            if rx == 1:
                x, y = s - 1 - x, s - 1 - y
            x, y = y, x
        x += s * rx
        y += s * ry
        t //= 4
        s *= 2
    return z, x, y


class Archive:
    """A local PMTiles file; directories are parsed once and kept."""

    def __init__(self, path):
        self.f = open(path, "rb")
        self.header = read_header(self.f.read(HEADER_LEN))
        self._dirs = {}

    def _read(self, offset, length):
        self.f.seek(offset)
        return self.f.read(length)

    def metadata(self):
        h = self.header
        raw = self._read(h["metadata_offset"], h["metadata_length"])
        return json.loads(decompress(raw, h["internal_compression"]) or b"{}")

    def _directory(self, offset, length):
        key = (offset, length)
        if key not in self._dirs:
            raw = self._read(offset, length)
            self._dirs[key] = parse_directory(decompress(raw, self.header["internal_compression"]))
        return self._dirs[key]

    def entries(self):
        """Every tile entry (tile_id, offset, length, run_length), leaf directories expanded."""
        h = self.header
        stack = [(h["root_offset"], h["root_length"])]
        while stack:
            for tile_id, off, length, run in self._directory(*stack.pop()):
                if run == 0:
                    stack.append((h["leaf_offset"] + off, length))
                else:
                    yield tile_id, off, length, run

    def find(self, tile_id):
        h = self.header
        offset, length = h["root_offset"], h["root_length"]
        for _ in range(4):  # root + at most a few leaf levels
            entries = self._directory(offset, length)
            lo, hi = 0, len(entries) - 1
            hit = None
            while lo <= hi:  # last entry with id <= tile_id
                mid = (lo + hi) // 2
                if entries[mid][0] <= tile_id:
                    hit, lo = entries[mid], mid + 1
                else:
                    hi = mid - 1
            if hit is None:
                return None
            eid, off, ln, run = hit
            if run == 0:
                offset, length = h["leaf_offset"] + off, ln
                continue
            return (off, ln) if tile_id < eid + run else None
        return None

    def tile(self, z, x, y):
        loc = self.find(zxy_to_tileid(z, x, y))
        if loc is None:
            return None
        return decompress(self._read(self.header["data_offset"] + loc[0], loc[1]), self.header["tile_compression"])

    def tile_at(self, offset, length):
        return decompress(self._read(self.header["data_offset"] + offset, length), self.header["tile_compression"])


# --- MVT ---------------------------------------------------------------------------------

def _fields(buf):
    """(field number, wire type, value) of one protobuf message; length-delimited -> bytes."""
    pos, end = 0, len(buf)
    while pos < end:
        key, pos = read_varint(buf, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = read_varint(buf, pos)
        elif wire == 2:
            ln, pos = read_varint(buf, pos)
            val, pos = buf[pos:pos + ln], pos + ln
        elif wire == 1:
            val, pos = buf[pos:pos + 8], pos + 8
        elif wire == 5:
            val, pos = buf[pos:pos + 4], pos + 4
        else:
            raise ValueError(f"unsupported protobuf wire type {wire}")
        yield field, wire, val


def _packed(buf):
    out, pos = [], 0
    while pos < len(buf):
        v, pos = read_varint(buf, pos)
        out.append(v)
    return out


def _value(buf):
    for field, _, val in _fields(buf):
        if field == 1:
            return bytes(val).decode("utf-8")
        if field == 2:
            return struct.unpack("<f", val)[0]
        if field == 3:
            return struct.unpack("<d", val)[0]
        if field in (4, 5):
            return val
        if field == 6:
            return (val >> 1) ^ -(val & 1)
        if field == 7:
            return bool(val)
    return None


def decode_tile(data):
    """{layer: (extent, [feature])}; feature = {id, type, props, geometry (encoded commands)}."""
    layers = {}
    for field, _, layer_buf in _fields(data):
        if field != 3:
            continue
        name, extent, keys, values, feats = None, 4096, [], [], []
        for lf, _, lv in _fields(layer_buf):
            if lf == 1:
                name = bytes(lv).decode("utf-8")
            elif lf == 5:
                extent = lv
            elif lf == 3:
                keys.append(bytes(lv).decode("utf-8"))
            elif lf == 4:
                values.append(_value(lv))
            elif lf == 2:
                feats.append(lv)
        out = []
        for fb in feats:
            fid, ftype, tags, geom = 0, 0, [], []  # an absent id is the protobuf default 0
            for ff, _, fv in _fields(fb):
                if ff == 1:
                    fid = fv
                elif ff == 2:
                    tags = _packed(fv)
                elif ff == 3:
                    ftype = fv
                elif ff == 4:
                    geom = _packed(fv)
            props = {keys[tags[i]]: values[tags[i + 1]] for i in range(0, len(tags) - 1, 2)}
            out.append({"id": fid, "type": ftype, "props": props, "geometry": geom})
        layers[name] = (extent, out)
    return layers


def geometry_parts(geom):
    """Decode MVT geometry commands into point lists (rings for polygons, lines, or points)."""
    parts, cur = [], None
    x = y = i = 0
    while i < len(geom):
        cmd, count = geom[i] & 7, geom[i] >> 3
        i += 1
        if cmd == 7:  # ClosePath
            continue
        for _ in range(count):
            dx, dy = geom[i], geom[i + 1]
            i += 2
            x += (dx >> 1) ^ -(dx & 1)
            y += (dy >> 1) ^ -(dy & 1)
            if cmd == 1:  # MoveTo starts a new part
                cur = [(x, y)]
                parts.append(cur)
            else:
                cur.append((x, y))
    return parts


def point_in_rings(px, py, rings):
    """Even-odd test over all rings of a feature (holes included)."""
    inside = False
    for ring in rings:
        n = len(ring)
        for k in range(n):
            x1, y1 = ring[k]
            x2, y2 = ring[(k + 1) % n]
            if (y1 > py) != (y2 > py) and px < (x2 - x1) * (py - y1) / (y2 - y1) + x1:
                inside = not inside
    return inside


def dist_to_parts(px, py, parts):
    best = float("inf")
    for pts in parts:
        if len(pts) == 1:
            best = min(best, math.hypot(px - pts[0][0], py - pts[0][1]))
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            dx, dy = x2 - x1, y2 - y1
            t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / (dx * dx + dy * dy)))
            best = min(best, math.hypot(px - (x1 + t * dx), py - (y1 + t * dy)))
    return best


def lonlat_to_tile(lon, lat, z):
    """Fractional tile coordinates (Web Mercator, y down)."""
    n = 1 << z
    lat_r = math.radians(max(-85.0511, min(85.0511, lat)))
    return (lon + 180.0) / 360.0 * n, (1 - math.asinh(math.tan(lat_r)) / math.pi) / 2 * n


# --- commands ----------------------------------------------------------------------------

def cmd_info(args):
    arc = Archive(args.file)
    print(json.dumps({"header": arc.header, "metadata": arc.metadata()}, indent=1, ensure_ascii=False))


def _copy(src, dst, start, stop):
    src.seek(start)
    left = stop - start
    while left > 0:
        chunk = src.read(min(left, 64 << 20))
        if not chunk:
            raise SystemExit("archive is shorter than its header says")
        dst.write(chunk)
        left -= len(chunk)


def cmd_set_metadata(args):
    """Copy IN to OUT with metadata keys replaced.

    Every byte outside the metadata section is copied as is (planetiler puts the metadata and
    leaf directories after the tile data); sections that start after the old metadata move by
    the change in its length, and the header offsets follow them.
    """
    with open(args.src, "rb") as f:
        head = f.read(HEADER_LEN)
        h = read_header(head)
        f.seek(0, 2)
        size = f.tell()
        mo, ml = h["metadata_offset"], h["metadata_length"]
        f.seek(mo)
        meta = json.loads(decompress(f.read(ml), h["internal_compression"]) or b"{}")
        for item in args.pairs:
            key, _, raw = item.partition("=")
            meta[key] = json.loads(raw)
        body = json.dumps(meta, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        new_meta = gzip.compress(body, mtime=0) if h["internal_compression"] == "gzip" else body
        shift = len(new_meta) - ml
        hdr = bytearray(head)
        struct.pack_into("<Q", hdr, 32, len(new_meta))
        for pos, key in ((8, "root_offset"), (40, "leaf_offset"), (56, "data_offset")):
            if h[key] >= mo + ml:
                struct.pack_into("<Q", hdr, pos, h[key] + shift)
            elif h[key] > mo:
                raise SystemExit(f"{key} points into the metadata section; refusing to rewrite")
        with open(args.dst, "wb") as out:
            out.write(hdr)
            _copy(f, out, HEADER_LEN, mo)
            out.write(new_meta)
            _copy(f, out, mo + ml, size)
    print(json.dumps({k: meta[k] for k in sorted(meta) if k not in ("vector_layers", "json")}, ensure_ascii=False))


def layerstats_summary(path):
    """Per layer: tile-feature count (a feature cut by N tiles counts N), tiles, bytes; by zoom."""
    layers = defaultdict(lambda: {"tile_features": 0, "tiles": 0, "bytes": 0, "by_zoom": defaultdict(lambda: [0, 0])})
    with gzip.open(path, "rt") as f:
        cols = f.readline().rstrip("\n").split("\t")
        ix = {c: i for i, c in enumerate(cols)}
        for line in f:
            row = line.rstrip("\n").split("\t")
            layer = layers[row[ix["layer"]]]
            feats = int(row[ix["layer_features"]])
            layer["tile_features"] += feats
            layer["tiles"] += 1
            layer["bytes"] += int(row[ix["layer_bytes"]])
            bz = layer["by_zoom"][int(row[ix["z"]])]
            bz[0] += 1
            bz[1] += feats
    out = {}
    for name, v in sorted(layers.items()):
        v["by_zoom"] = {str(z): {"tiles": t, "tile_features": n} for z, (t, n) in sorted(v["by_zoom"].items())}
        out[name] = v
    return out


def match_feature(feat, cp):
    props = feat["props"]
    for k, v in (cp.get("match") or {}).items():
        if str(props.get(k)) != str(v):
            return False
    for k, pattern in (cp.get("match_re") or {}).items():
        if props.get(k) is None or not re.search(pattern, str(props[k])):
            return False
    return True


def run_checkpoint(arc, cp):
    """One checkpoint at each of its zooms; returns (ok, detail)."""
    zooms = cp["z"] if isinstance(cp["z"], list) else [cp["z"]]
    details = []
    ok_all = True
    for z in zooms:
        fx, fy = lonlat_to_tile(cp["lon"], cp["lat"], z)
        x, y = int(fx), int(fy)
        data = arc.tile(z, x, y)
        if data is None:
            details.append(f"z{z}: no tile {z}/{x}/{y}")
            ok_all = False
            continue
        extent, feats = decode_tile(data).get(cp["layer"], (4096, []))
        px, py = (fx - x) * extent, (fy - y) * extent
        cands = [f for f in feats if match_feature(f, cp)]
        if cp.get("contains"):
            hit = next((f for f in cands if f["type"] == 3 and point_in_rings(px, py, geometry_parts(f["geometry"]))), None)
            if hit is None:
                details.append(f"z{z}: point not inside any of {len(cands)} matching {cp['layer']} polygons")
                ok_all = False
            else:
                details.append(f"z{z}: inside id {hit['id']} {hit['props'].get('name', '')}".rstrip())
        else:
            # metres per tile unit at this latitude
            unit_m = EARTH_CIRCUMFERENCE_M * math.cos(math.radians(cp["lat"])) / (1 << z) / extent
            best = min(((dist_to_parts(px, py, geometry_parts(f["geometry"])) * unit_m, f) for f in cands),
                       default=(None, None), key=lambda t: t[0])
            if best[1] is None or best[0] > cp.get("within_m", 500):
                details.append(f"z{z}: no matching {cp['layer']} feature within {cp.get('within_m', 500)} m"
                               f" ({len(cands)} matching in tile)")
                ok_all = False
            else:
                details.append(f"z{z}: id {best[1]['id']} {best[1]['props'].get('name', '')} at {best[0]:.0f} m")
    return ok_all, "; ".join(details)


def check_ids(arc, sample_every):
    """Feature ids in every Nth distinct tile: OSM layers id % 10 in 1..3, ocean id 0."""
    bad, seen, checked = Counter(), set(), 0
    for k, (tile_id, off, length, run) in enumerate(arc.entries()):
        if (off, length) in seen or k % sample_every:
            continue
        seen.add((off, length))
        checked += 1
        for name, (_, feats) in decode_tile(arc.tile_at(off, length)).items():
            for f in feats:
                fid = f["id"]
                if name == "ocean":
                    if fid != 0:
                        bad[name] += 1
                elif fid % 10 not in (1, 2, 3):
                    bad[name] += 1
    return checked, dict(bad)


def decode_all(arc):
    """Distinct feature ids per layer overall and at max zoom (small archives only)."""
    ids, ids_max, contents = defaultdict(set), defaultdict(set), {}
    maxz = arc.header["max_zoom"]
    for tile_id, off, length, run in arc.entries():
        key = (off, length)
        if key not in contents:
            contents[key] = [(name, f["id"]) for name, (_, feats) in decode_tile(arc.tile_at(off, length)).items()
                             for f in feats]
        at_max = tileid_zoom(tile_id) == maxz
        for name, fid in contents[key]:
            ids[name].add(fid)
            if at_max:
                ids_max[name].add(fid)
    return {name: {"distinct_ids": len(v), f"distinct_ids_z{maxz}": len(ids_max.get(name, ()))}
            for name, v in sorted(ids.items())}


def cmd_verify(args):
    arc = Archive(args.file)
    h = arc.header
    meta = arc.metadata()
    failures, warnings = [], []
    if h["tile_type"] != "mvt" or h["tile_compression"] != "gzip":
        failures.append(f"tiles are {h['tile_type']}/{h['tile_compression']}, expected mvt/gzip")
    if (h["min_zoom"], h["max_zoom"]) != (5, 14):
        failures.append(f"zoom range z{h['min_zoom']}-{h['max_zoom']}, expected z5-14")
    if not h["clustered"]:
        failures.append("archive is not clustered")
    missing = [k for k in REQUIRED_METADATA if k not in meta]
    if missing:
        failures.append(f"metadata lacks {', '.join(missing)}")
    vector_layers = sorted(v["id"] for v in (meta.get("vector_layers") or []))
    unknown = sorted(set(vector_layers) - set(CONTRACT_LAYERS))
    if unknown:
        failures.append(f"layers outside the contract: {', '.join(unknown)}")

    report = {"file": args.file, "header": h,
              "metadata": {k: v for k, v in meta.items() if k not in ("vector_layers", "json")},
              "vector_layers": vector_layers}
    if args.sha256:
        sha = hashlib.sha256()
        with open(args.file, "rb") as f:
            while chunk := f.read(16 << 20):
                sha.update(chunk)
        report["sha256"] = sha.hexdigest()

    layers = layerstats_summary(args.layerstats) if args.layerstats else {}
    if args.decode_all:
        for name, v in decode_all(arc).items():
            layers.setdefault(name, {}).update(v)
    report["layers"] = layers
    for name in filter(None, (args.require_layers or "").split(",")):
        if not layers.get(name, {}).get("tile_features") and not layers.get(name, {}).get("distinct_ids"):
            failures.append(f"layer {name} is empty")

    checked, bad_ids = check_ids(arc, args.id_sample_every)
    report["id_check"] = {"tiles_checked": checked, "bad_ids": bad_ids}
    if bad_ids:
        failures.append(f"unexpected feature ids: {bad_ids}")

    cps = []
    if args.checkpoints:
        with open(args.checkpoints) as f:
            spec = json.load(f)
        w, s, e, n = h["bounds"]
        for cp in spec["checkpoints"]:
            entry = {"name": cp["name"], "layer": cp["layer"]}
            if not (w <= cp["lon"] <= e and s <= cp["lat"] <= n):
                entry["result"] = "skipped (outside bounds)"
            else:
                ok, detail = run_checkpoint(arc, cp)
                entry["result"] = "ok" if ok else "FAIL"
                entry["detail"] = detail
                if not ok:
                    failures.append(f"checkpoint {cp['name']}: {detail}")
            cps.append(entry)
        if args.min_checkpoints and sum(c["result"] == "ok" for c in cps) < args.min_checkpoints:
            failures.append(f"fewer than {args.min_checkpoints} checkpoints apply to this archive")
    report["checkpoints"] = cps

    if args.prev_manifest and layers:
        with open(args.prev_manifest) as f:
            prev = json.load(f).get("layers", {})
        for name, v in layers.items():
            old = prev.get(name, {}).get("tile_features")
            new = v.get("tile_features")
            if not old or new is None:
                continue
            change = new / old - 1
            if change < -args.max_drop:
                failures.append(f"layer {name}: {old} -> {new} tile features ({change:+.1%}) vs previous build")
            elif abs(change) > args.warn_change:
                warnings.append(f"layer {name}: {old} -> {new} tile features ({change:+.1%}) vs previous build")
    report["warnings"] = warnings
    report["failures"] = failures
    with open(args.out, "w") as f:
        json.dump(report, f, indent=1, ensure_ascii=False)
    for c in cps:
        print(f"checkpoint {c['result']:>24}  {c['name']}" + (f"  [{c.get('detail')}]" if c.get("detail") else ""))
    for name, v in layers.items():
        print(f"layer {name:9} " + "  ".join(f"{k}={v[k]}" for k in v if k != "by_zoom"))
    for msg in warnings:
        print("WARNING:", msg)
    for msg in failures:
        print("FAIL:", msg)
    return 1 if failures else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("info")
    p.add_argument("file")
    p = sub.add_parser("set-metadata")
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("pairs", nargs="+", metavar="KEY=JSON")
    p = sub.add_parser("verify")
    p.add_argument("file")
    p.add_argument("--out", required=True)
    p.add_argument("--layerstats")
    p.add_argument("--checkpoints")
    p.add_argument("--min-checkpoints", type=int, default=0)
    p.add_argument("--require-layers")
    p.add_argument("--prev-manifest")
    p.add_argument("--max-drop", type=float, default=0.25, help="fail when a layer shrinks more than this")
    p.add_argument("--warn-change", type=float, default=0.05)
    p.add_argument("--id-sample-every", type=int, default=1000, help="check ids in every Nth tile entry")
    p.add_argument("--decode-all", action="store_true", help="count distinct ids per layer (small archives)")
    p.add_argument("--sha256", action="store_true")
    args = ap.parse_args()
    if args.cmd == "info":
        return cmd_info(args)
    if args.cmd == "set-metadata":
        return cmd_set_metadata(args)
    return cmd_verify(args)


if __name__ == "__main__":
    sys.exit(main() or 0)
