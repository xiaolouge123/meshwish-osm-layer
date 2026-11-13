"""Build manifest and PMTiles metadata for scripts/build.sh.

    python3 -I manifest.py metadata PARTS_DIR        -> KEY=JSON lines for pmtiles_tool.py set-metadata
    python3 -I manifest.py assemble PARTS_DIR OUT.json

PARTS_DIR holds what build.sh collected on the way:
  build.kv            key=value lines (build id, scope, sources, checksums, tool versions, timings)
  osm_header.json     `osmium fileinfo -j` of the OSM input (replication timestamp, sequence, URL, box)
  needed_info.json    `osmium fileinfo -e -j` of the filtered input (object counts)
  raw_metadata.json   `pmtiles_tool.py info` of planetiler's output, before our keys are added
  osmdata_stats.json, osmdata_check.json, osmdata_prev_stats.json (optional)
  verify.json         `pmtiles_tool.py verify` report of the final archive

The manifest is the record that makes a build reproducible and the layer's ODbL "method"
statement concrete: which planet (date, replication sequence, md5), which water polygons
(date, sha256), which rules (sha256 of schema/meshwish-osm.yml) and which tools (image digests,
package versions) produced the archive with this sha256.
"""

import json
import os
import sys

MANIFEST_VERSION = 1
ATTRIBUTION_TEXT = "© OpenStreetMap contributors"


def load(parts, name, default=None):
    path = os.path.join(parts, name)
    if not os.path.exists(path):
        return default
    with open(path) as f:
        return json.load(f)


def load_kv(parts):
    kv = {}
    with open(os.path.join(parts, "build.kv")) as f:
        for line in f:
            if "=" in line:
                k, _, v = line.rstrip("\n").partition("=")
                kv[k] = v
    return kv


def osm_header(parts):
    h = load(parts, "osm_header.json", {}).get("header", {})
    opt = h.get("option", {})
    ts = opt.get("osmosis_replication_timestamp") or opt.get("timestamp")
    seq = opt.get("osmosis_replication_sequence_number")
    return {"replication_timestamp": ts, "replication_sequence": int(seq) if seq else None,
            "replication_url": opt.get("osmosis_replication_base_url"),
            "generator": opt.get("generator"), "bbox": (h.get("boxes") or [None])[0]}


def schema_version(parts):
    meta = load(parts, "raw_metadata.json")["metadata"]
    return int(meta["version"])


def cmd_metadata(parts):
    kv = load_kv(parts)
    osm = osm_header(parts)
    osmdata = load(parts, "osmdata_stats.json", {})
    pairs = {
        "meshwish_schema": schema_version(parts),
        "planet_date": (osm["replication_timestamp"] or "")[:10],
        "planet_sequence": osm["replication_sequence"],
        "osmdata_date": (osmdata.get("data_date") or "")[:10],
        "build_id": kv["build_id"],
        "license": "ODbL-1.0",
        "attribution_text": ATTRIBUTION_TEXT,
    }
    if kv.get("method_url"):
        pairs["method_url"] = kv["method_url"]
    for k, v in pairs.items():
        print(f"{k}={json.dumps(v, ensure_ascii=False)}")


def cmd_assemble(parts, out):
    kv = load_kv(parts)
    osm = osm_header(parts)
    verify = load(parts, "verify.json", {})
    needed = load(parts, "needed_info.json", {})
    counts = (needed.get("data") or {}).get("count", {})
    timings = {k[len("time_"):]: int(v) for k, v in kv.items() if k.startswith("time_")}
    manifest = {
        "manifest_version": MANIFEST_VERSION,
        "build_id": kv["build_id"],
        "created_at": kv["created_at"],
        "scope": {"mode": kv["mode"], "name": kv["scope"], "region": kv.get("region") or None,
                  "bbox": [float(v) for v in kv["bbox"].split(",")] if kv.get("bbox") else None},
        "license": "ODbL-1.0",
        "attribution": ATTRIBUTION_TEXT + ", https://www.openstreetmap.org/copyright",
        "method": {"repository": kv.get("method_url") or None, "commit": kv.get("repo_commit") or None,
                   "tools_version": kv["tools_version"]},
        "inputs": {
            "osm": {"url": kv.get("osm_url") or None, "file": kv["osm_file"], "bytes": int(kv["osm_bytes"]),
                    "md5": kv.get("osm_md5") or None, "md5_verified": kv.get("osm_md5_verified") == "1",
                    **{k: v for k, v in osm.items() if k != "generator"},
                    "filtered": {"bytes": int(kv["needed_bytes"]), "nodes": counts.get("nodes"),
                                 "ways": counts.get("ways"), "relations": counts.get("relations")}},
            "osmdata": {"url": kv.get("osmdata_url") or None, "status": kv["osmdata_status"],
                        "last_modified": kv.get("osmdata_last_modified") or None,
                        "stats": load(parts, "osmdata_stats.json"),
                        "previous": load(parts, "osmdata_prev_stats.json"),
                        "check": load(parts, "osmdata_check.json")},
        },
        "rules": {"schema": "schema/meshwish-osm.yml", "schema_sha256": kv["schema_sha256"],
                  "spec_sha256": kv["spec_sha256"], "meshwish_schema": schema_version(parts),
                  "osmium_tags_filter": kv["osmium_filter"].split()},
        "tools": {"planetiler_image": kv["planetiler_image"],
                  "planetiler_version": verify.get("metadata", {}).get("planetiler:version"),
                  "planetiler_githash": verify.get("metadata", {}).get("planetiler:githash"),
                  "tools_base_image": kv["tools_base_image"], "tools_image_id": kv["tools_image_id"],
                  "packages": dict(p.split("=", 1) for p in kv["packages"].split(";") if "=" in p),
                  "planetiler_args": kv["planetiler_args"].split()},
        "output": {"file": kv["output_file"], "bytes": int(kv["output_bytes"]), "sha256": kv["output_sha256"],
                   "header": verify.get("header"), "metadata": verify.get("metadata")},
        "layers": verify.get("layers"),
        "checks": {"id_check": verify.get("id_check"), "checkpoints": verify.get("checkpoints"),
                   "warnings": verify.get("warnings"), "failures": verify.get("failures")},
        "timings_s": timings,
        "resources": {k: kv[k] for k in ("pt_memory", "pt_xmx", "pt_cpus", "host_cpus", "host_mem_gib") if k in kv},
    }
    with open(out, "w") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "metadata":
        return cmd_metadata(sys.argv[2])
    if len(sys.argv) >= 4 and sys.argv[1] == "assemble":
        return cmd_assemble(sys.argv[2], sys.argv[3])
    sys.exit(__doc__)


if __name__ == "__main__":
    main()
