"""latest.json and manifest helpers for upload.sh and fetch-previous.sh.

    python3 -I latest.py get JSON KEY.PATH          print one value ("" when missing)
    python3 -I latest.py next OLD|- MANIFEST PREFIX OUT [--no-osmdata]
    python3 -I latest.py keep LATEST                print the build ids to keep (current, previous)

latest.json is the pointer readers and the next build follow:
  {"latest_version": 1, "updated_at": ...,
   "current":  {build_id, pmtiles (key), manifest (key), bytes, sha256, meshwish_schema,
                planet_date, osmdata_date},
   "previous": the former "current" (kept for rollback) or null,
   "osmdata":  {data_date, zip (key), stats (key)}   last accepted water polygons}
Keys are relative to the bucket. `next` moves "current" to "previous" unless the new build has
the same id (a re-upload), and keeps the old "osmdata" entry when this build used a given or
fallback file rather than a newly accepted one.
"""

import json
import sys
from datetime import datetime, timezone


def get(obj, path):
    for part in path.split("."):
        if not isinstance(obj, dict) or part not in obj:
            return ""
        obj = obj[part]
    return obj if not isinstance(obj, (dict, list)) else json.dumps(obj)


def load(path):
    if path == "-":
        return None
    with open(path) as f:
        return json.load(f)


def cmd_next(old_path, manifest_path, prefix, out, no_osmdata):
    old = load(old_path) or {}
    m = load(manifest_path)
    base = f"{prefix}/builds/{m['build_id']}" if prefix else f"builds/{m['build_id']}"
    meta = m["output"].get("metadata") or {}
    current = {"build_id": m["build_id"], "pmtiles": f"{base}/{m['output']['file']}",
               "manifest": f"{base}/manifest.json", "bytes": m["output"]["bytes"],
               "sha256": m["output"]["sha256"], "meshwish_schema": meta.get("meshwish_schema"),
               "planet_date": meta.get("planet_date"), "osmdata_date": meta.get("osmdata_date")}
    prev = old.get("current")
    if prev and prev.get("build_id") == current["build_id"]:
        prev = old.get("previous")
    osmdata = old.get("osmdata")
    stats = m["inputs"]["osmdata"]["stats"] or {}
    if not no_osmdata and m["inputs"]["osmdata"]["status"] in ("accepted", "first_build"):
        day = (stats.get("data_date") or "")[:10]
        okey = f"{prefix}/osmdata/{day}" if prefix else f"osmdata/{day}"
        osmdata = {"data_date": stats.get("data_date"), "zip": f"{okey}/{stats['file']}",
                   "stats": f"{okey}/stats.json", "sha256": stats.get("sha256")}
    new = {"latest_version": 1, "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "current": current, "previous": prev, "osmdata": osmdata}
    with open(out, "w") as f:
        json.dump(new, f, indent=1)
    print(json.dumps(new))


def main():
    a = sys.argv[1:]
    if len(a) == 3 and a[0] == "get":
        print(get(load(a[1]), a[2]))
    elif len(a) >= 5 and a[0] == "next":
        cmd_next(a[1], a[2], a[3], a[4], "--no-osmdata" in a)
    elif len(a) == 2 and a[0] == "keep":
        latest = load(a[1])
        for k in ("current", "previous"):
            if latest.get(k):
                print(latest[k]["build_id"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
