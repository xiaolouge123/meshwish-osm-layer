# meshwish OSM layer

Source: https://github.com/xiaolouge123/meshwish-osm-layer

[meshwish](https://meshwish.ai) turns places into 3D-printable terrain models. The lakes, rivers,
glaciers, paths, roads, peaks and sea on those models come from OpenStreetMap, through one file:
a PMTiles archive of vector tiles (z5–14) built from the full OSM planet once a month. This
repository is how that file is made: the selection rules, the build and check scripts, and the
monthly job that runs them.

- `schema/meshwish-osm.yml` – the rules: which OSM tags go into which layer, from which zoom,
  with which attributes and how much simplification (a [planetiler](https://github.com/onthegomap/planetiler)
  custom-map profile). Its header comment documents the layer contract readers rely on.
- `schema/meshwish-osm.spec.yml` – rule tests run before every build;
  `schema/checkpoints.json` – known places every finished build is checked at.
- `scripts/build.sh` – download, filter, tile, annotate, check, write the manifest.
- `scripts/upload.sh`, `scripts/fetch-previous.sh` – publish a build to S3-compatible storage
  (Cloudflare R2) and fetch what the next build compares with.
- `hetzner/` – run one build on a short-lived Hetzner Cloud server that deletes itself.
- `ops/` – or run the monthly build from a systemd timer on a server of ours (`ops/README.md`).
- `versions.env` – pinned tool images; `docker/tools.Dockerfile` – osmium and Python.

## Licence of the data (ODbL)

The layer is a **Derivative Database of OpenStreetMap** and is available under the
[Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/):
© OpenStreetMap contributors, <https://www.openstreetmap.org/copyright>.

It holds only OpenStreetMap data: OSM objects selected and simplified by the rules here, and the
water polygons of [osmdata.openstreetmap.de](https://osmdata.openstreetmap.de/data/water-polygons.html),
which are computed from the OSM coastline and are ODbL as well. Nothing from other sources is
mixed in.

ODbL §4.6 asks whoever publicly uses a Derivative Database, or a Produced Work made from it (a
terrain model), to offer either the database or "a file containing all of the alterations made to
the Database or the method of making the alterations to the Database (such as an algorithm)".
This repository is that method (§4.6b): the rules, the scripts and, for every build, a manifest
naming the exact inputs and tools. With them anyone can rebuild the layer from public data.

The scripts themselves are MIT licensed (`LICENSE`).

### Attribution

Anyone using the layer, or anything made from it, credits OpenStreetMap:

> © OpenStreetMap contributors – https://www.openstreetmap.org/copyright

and makes clear the data is available under the ODbL. For printed or other physical objects,
the [OSMF Attribution Guidelines](https://osmfoundation.org/wiki/Licence/Attribution_Guidelines)
apply (credit on the object, its packaging or where it is offered). meshwish shows the credit on
model pages, in the viewer, in downloaded files' metadata and in its "data sources" page, which
links to the build of this repository that made the layer.

## What a build contains

One PMTiles v3 archive, gzip-compressed Mapbox Vector Tiles, z5–14, tiles clustered:

| layer | from OSM | attributes |
|---|---|---|
| `water` | `natural=water`, `landuse=reservoir`, `waterway=riverbank` | `water`, `name` |
| `glacier` | `natural=glacier` | `name` |
| `waterway` | `waterway=river\|stream\|canal` (no culverts, no intermittent streams) | `waterway`, `name`, `width` |
| `path` | `highway=path\|footway\|bridleway\|steps\|track\|via_ferrata` (no sidewalks or crossings) | `highway`, `name`, `sac_scale` |
| `road` | `highway=motorway` … `tertiary` and their links | `highway` |
| `peak` | `natural=peak\|volcano` | `name`, `ele`, `natural` |
| `ocean` | osmdata water polygons (split, WGS84) | – |

Feature ids are `osm_id × 10 + 1/2/3` (node/way/relation); ocean features all have id 0. Zoom
gates, size thresholds and simplification follow print scale, see the schema's header comment.
Archive metadata adds `meshwish_schema` (rule version, integer), `planet_date`,
`planet_sequence`, `osmdata_date`, `build_id`, `license` and `method_url` to planetiler's
standard keys.

## Reproducing a build

Each build writes `manifest.json` next to the archive (published with it). To rebuild one:

1. **OSM input** – `inputs.osm`: file name, md5, replication timestamp and sequence number. Weekly
   planet files are published at <https://planet.openstreetmap.org/pbf/> and its mirrors; a
   Geofabrik extract is named by its URL and replication sequence.
2. **Water polygons** – `inputs.osmdata`: data date ("Date of the data used" in the zip's README),
   sha256, and the statistics the file was checked with. osmdata.openstreetmap.de publishes only
   the current file; the build that used it keeps the accepted copy.
3. **Rules** – `rules.schema_sha256` is the sha256 of `schema/meshwish-osm.yml`; `method.commit`
   the commit of this repository (and `method_url` in the archive metadata links to it).
4. **Tools** – `tools.planetiler_image` (pinned by digest), `tools.tools_base_image` and
   `tools.packages` (osmium-tool and Python from Debian), `tools.planetiler_args`.
5. Check out that commit and run the same mode, e.g. `scripts/build.sh --planet 261109`.

The same inputs, rules and pinned tools give the same features, ids and attributes; byte-identical
archives are not promised across planetiler versions or settings.

### Build manifest (`manifest_version` 1)

| key | content |
|---|---|
| `build_id` | `<OSM data date>-<scope>-<build time UTC>`, e.g. `20261109-planet-20261113T0412Z` |
| `created_at`, `scope` | build start; mode (`planet`, `region`, `file`), name, Geofabrik region, bbox |
| `license`, `attribution`, `method` | ODbL-1.0; credit line; repository URL, commit, tools version |
| `inputs.osm` | URL, file, bytes, md5 (and whether it was verified), replication timestamp / sequence / URL, bbox; `filtered`: size and node / way / relation counts after the tag filter |
| `inputs.osmdata` | URL, status (`accepted`, `first_build`, `fallback_previous`, `given`), Last-Modified, `stats` (data date, sha256, features, rings, vertices, area km², extent), `previous` stats, `check` result |
| `rules` | schema path and sha256, rule-test sha256, `meshwish_schema`, the osmium tag filter |
| `tools` | planetiler image digest, version and git hash; tools image base digest, id and package versions; planetiler arguments |
| `output` | file, bytes, sha256, PMTiles header and metadata |
| `layers` | per layer: tile-feature count (a feature cut into N tiles counts N), tiles, bytes, per zoom; distinct ids for small builds |
| `checks` | id check, checkpoints, warnings, failures (upload refuses a build with failures) |
| `timings_s`, `resources` | seconds per step; container limits and host size |

## Running a build

Needs bash, curl and docker; everything else runs in containers.

```sh
# a small area, for testing (minutes; a few GB of RAM)
scripts/build.sh --region europe/malta --work /data/osm
scripts/build.sh --region europe/switzerland --bbox 7.55,45.92,8.07,46.19 --name zermatt

# what would be downloaded (resolves "latest", fetches only the md5; leaves no files behind)
scripts/build.sh --planet latest --dry-run
scripts/build.sh --region europe --dry-run

# the planet (about 1 h on 16 cores / 64 GB, ~120 GB of disk at the peak; measured 2026-11-14:
# 61 min, 18 GB of RAM in use plus page cache for the 50 GB node map, a 27 GB archive)
prev=$(scripts/fetch-previous.sh /data/osm/prev)   # needs the storage env below
scripts/build.sh --planet latest $prev --work /data/osm/work --delete-input
scripts/upload.sh /data/osm/work/builds/<build_id>
```

`build.sh` steps: rule tests → OSM download with md5 check (planet: md5 from
planet.openstreetmap.org, data from `$PLANET_MIRROR`; Geofabrik: md5 next to the file, which for
the largest extracts such as `europe` is on the mirror Geofabrik redirects to) → `osmium tags-filter` without metadata
(no user names) and optional `--bbox` cut → water polygons: download, statistics, comparison with
the last accepted file (features ±2%, vertices ±5%, area ±0.1%, same extent, data date not
older; otherwise the previous file is used) → planetiler → metadata → checks (header, metadata,
layer counts, ids, checkpoints, change against the previous build) → manifest. Resource limits:
`PT_MEMORY`, `PT_XMX`, `PT_CPUS`, `PT_TIMEOUT` (planetiler), `TOOLS_MEMORY`, `TOOLS_TIMEOUT`;
`DOCKER_RUN_ARGS` adds options to every container (the monthly job's slice and run label).
For a local test with a small area, `--ocean-zip` takes a clip of the water polygons made with
`scripts/tools/osmdata_tool.py clip` instead of the 900 MB file; with a 1° margin around the
area the tiles come out identical.

Every request carries the User-Agent `meshwish-osm-layer/<version> (+https://meshwish.ai)`. Each
file is downloaded once and reused while its checksum holds.

### Storage layout

`upload.sh` writes under `OSM_S3_URI` (e.g. `s3://bucket/osm-layer`):

```
builds/<build_id>/meshwish-osm.pmtiles   archive (metadata x-amz-meta-sha256)
builds/<build_id>/manifest.json
osmdata/<date>/water-polygons-split-4326.zip, stats.json   last accepted water polygons
latest.json                              pointer, replaced last in a single PUT
logs/<time>-<ok|failed>/                 logs of Hetzner runs
```

`latest.json`:

```json
{"latest_version": 1, "updated_at": "2026-11-13T05:10:00Z",
 "current":  {"build_id": "...", "pmtiles": "osm-layer/builds/<id>/meshwish-osm.pmtiles",
              "manifest": "osm-layer/builds/<id>/manifest.json", "bytes": 0, "sha256": "...",
              "meshwish_schema": 1, "planet_date": "2026-11-09", "osmdata_date": "2026-11-11"},
 "previous": {"...": "the build that was current before, kept for rollback"},
 "osmdata":  {"data_date": "...", "zip": "osm-layer/osmdata/<date>/...", "stats": "...", "sha256": "..."}}
```

Environment: `OSM_S3_URI`, `OSM_S3_ENDPOINT` (R2: `https://<account id>.r2.cloudflarestorage.com`),
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` (an R2 API token with Object Read & Write on this
bucket only), `AWS_DEFAULT_REGION` (default `auto`). `upload.sh --no-latest` uploads a build
without making it current; `--prune` deletes builds other than current and previous.

## Monthly build

Two ways to run it every month: a short-lived Hetzner Cloud server per build (below), or a
systemd timer on a server that stays up, which builds the newest planet with the release tag
it is pinned to, uploads it with `--prune` only when its checks pass, skips an unchanged
planet, and can mail a failed or skipped run (`ops/README.md`, `ops/notify-email.sh`).

`hetzner/launch.sh` creates a server (default CCX43: 16 dedicated vCPU, 64 GB RAM, 360 GB disk,
Falkenstein), passes it the settings through cloud-init, and returns. The server installs
docker, clones this repository at `REPO_REF`, runs `fetch-previous.sh`, `build.sh` and
`upload.sh`, uploads its logs, and deletes itself. Three guards keep it from running on:
deletion at the end of the run (success or failure), a systemd timer at boot that deletes it
after `MAX_HOURS` (default 6), and the `delete-after` label that `launch.sh --wait` and
`hetzner/reap.sh` act on.

```sh
export HCLOUD_TOKEN=...        # token of a Hetzner project used only for these builds
export REPO_URL=https://github.com/<owner>/<repo>.git REPO_REF=<tag or commit>
export OSM_S3_URI=s3://<bucket>/osm-layer OSM_S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
export SSH_KEY=<key name in the project>   # optional, for logging in to watch or debug

# European test run first: one Geofabrik extract, uploaded without becoming "latest"
BUILD_ARGS="--region europe" UPLOAD_ARGS="--no-latest" hetzner/launch.sh --wait

# then the planet, monthly
hetzner/launch.sh --wait
```

The server receives the Hetzner token (to delete itself) and the storage key; keep the Hetzner
project for this job alone and scope the storage key to the one bucket.

**Cost** (Hetzner list prices of November 2026; check the console): CCX43 about €0.44/h, IPv4
about €0.001/h, incoming traffic free. Planet build about 1–1.5 h ≈ €0.5–0.7 (61 min on a 16-core
dedicated server); European test run about 30 min with setup and upload ≈ €0.25; a stuck run is
deleted after 6 h ≈ €2.7 at most. R2 storage about $0.015 per GB-month: ~$0.4/month per planet
build kept (~27 GB), so current plus previous ≈ $0.8/month; reads stay in R2's free tier.
