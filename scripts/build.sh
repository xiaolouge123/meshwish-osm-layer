#!/usr/bin/env bash
# Build the meshwish OSM layer: one PMTiles archive (z5-14) from the OSM planet or an extract.
#
#   scripts/build.sh [--planet latest|YYMMDD | --region GEOFABRIK_PATH | --pbf FILE] [options]
#
# Steps, each logged with its duration in the manifest:
#   1. rule tests: planetiler verify-custom runs schema/meshwish-osm.spec.yml against the rules;
#   2. OSM input: the weekly planet (md5 from planet.openstreetmap.org, file from $PLANET_MIRROR),
#      a Geofabrik extract (--region, e.g. "europe" for the European test run) or a local file;
#      checked against its .md5, downloaded once and reused while it verifies;
#   3. osmium tags-filter keeps only the tags the rules read (and the nodes and members those
#      objects need), without metadata (no user names, versions or changesets); --bbox then cuts
#      the result with osmium extract --strategy smart;
#   4. water polygons from osmdata.openstreetmap.de: README data date, statistics, and the
#      comparison with the last accepted file (--prev-osmdata): features within 2%, vertices 5%,
#      area 0.1%; a file that fails is replaced by the previous one (scripts/tools/osmdata_tool.py);
#   5. planetiler generate-custom with schema/meshwish-osm.yml (image pinned by digest);
#   6. metadata: meshwish_schema, planet_date, osmdata_date, build_id, license, method_url;
#   7. checks: header, metadata, per-layer feature counts, feature ids, checkpoints at known
#      places (schema/checkpoints.json) and, with --prev-manifest, the change per layer;
#   8. manifest.json: inputs with dates, sequence and checksums, rule and tool versions, output
#      size and sha256 (scripts/tools/manifest.py).
# A failed check still writes the manifest (with its failures) and exits 1; upload.sh refuses it.
#
# Options:
#   --bbox W,S,E,N        cut the input to this box (degrees)
#   --name NAME           scope name in the build id (default: planet, the region path, or the file name)
#   --ocean-zip FILE      use this water polygon zip (a full file or a clip) instead of downloading
#   --prev-osmdata DIR    last accepted water polygons: DIR/stats.json and the zip it names
#   --prev-manifest FILE  manifest of the build this one replaces
#   --require-layers L    comma list of layers that must not be empty (planet and europe: all seven)
#   --work DIR            downloads, temp files and output (default ./work)
#   --delete-input        delete the OSM download once filtered (a planet is ~100 GB)
#   --dry-run             resolve the OSM file, fetch its md5, print what would be downloaded, stop
# Environment:
#   PLANET_MIRROR   default https://ftp.fau.de/osm-planet/pbf (any mirror of planet.openstreetmap.org/pbf)
#   METHOD_URL      public URL of this repository at the commit used, written into the metadata
#   PT_MEMORY, PT_XMX, PT_CPUS, PT_TIMEOUT   planetiler container limits (default 85% / 40% of RAM,
#                   all cores, 4 h); PT_EXTRA_ARGS adds planetiler arguments
#   TOOLS_MEMORY, TOOLS_CPUS, TOOLS_TIMEOUT  limits of the osmium / Python container (4g, 4, 6 h)
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

MODE=planet PLANET=latest REGION="" PBF="" BBOX="" NAME="" OCEAN_ZIP="" PREV_OSMDATA="" PREV_MANIFEST=""
REQUIRE_LAYERS="" WORK_DIR="$PWD/work" DELETE_INPUT=0 DRY_RUN=0
PLANET_ORIGIN=https://planet.openstreetmap.org/pbf
PLANET_MIRROR=${PLANET_MIRROR:-https://ftp.fau.de/osm-planet/pbf}
GEOFABRIK=https://download.geofabrik.de
OSMDATA_URL=https://osmdata.openstreetmap.de/download/water-polygons-split-4326.zip
ALL_LAYERS=water,glacier,waterway,path,road,peak,ocean
# Kept in step with the include_when lists of schema/meshwish-osm.yml.
OSMIUM_FILTER="w/highway=path,footway,bridleway,steps,track,via_ferrata,motorway,motorway_link,trunk,trunk_link,primary,primary_link,secondary,secondary_link,tertiary,tertiary_link wr/natural=water wr/landuse=reservoir wr/waterway=riverbank w/waterway=river,stream,canal wr/natural=glacier n/natural=peak,volcano"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit "${1:-0}"; }
while [[ $# -gt 0 ]]; do
  case $1 in
    --planet) MODE=planet PLANET=$2; shift 2 ;;
    --region) MODE=region REGION=${2%/}; shift 2 ;;
    --pbf) MODE=file PBF=$2; shift 2 ;;
    --bbox) BBOX=$2; shift 2 ;;
    --name) NAME=$2; shift 2 ;;
    --ocean-zip) OCEAN_ZIP=$2; shift 2 ;;
    --prev-osmdata) PREV_OSMDATA=$2; shift 2 ;;
    --prev-manifest) PREV_MANIFEST=$2; shift 2 ;;
    --require-layers) REQUIRE_LAYERS=$2; shift 2 ;;
    --work) WORK_DIR=$2; shift 2 ;;
    --delete-input) DELETE_INPUT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    *) log "unknown argument $1"; usage 2 ;;
  esac
done
if [[ -n "$BBOX" && ! "$BBOX" =~ ^-?[0-9.]+,-?[0-9.]+,-?[0-9.]+,-?[0-9.]+$ ]]; then
  die "--bbox wants W,S,E,N in degrees"
fi
case $MODE in
  planet) [[ "$PLANET" == latest || "$PLANET" =~ ^[0-9]{6}$ ]] || die "--planet wants latest or YYMMDD"
          NAME=${NAME:-planet}; REQUIRE_LAYERS=${REQUIRE_LAYERS:-$ALL_LAYERS}; MIN_CHECKPOINTS=5 ;;
  region) [[ "$REGION" =~ ^[a-z0-9/-]+$ ]] || die "--region wants a Geofabrik path such as europe/switzerland"
          NAME=${NAME:-${REGION//\//-}}; MIN_CHECKPOINTS=0
          [[ "$REGION" == europe ]] && { REQUIRE_LAYERS=${REQUIRE_LAYERS:-$ALL_LAYERS}; MIN_CHECKPOINTS=3; } ;;
  file) [[ -f "$PBF" ]] || die "no such file: $PBF"
        NAME=${NAME:-$(basename "$PBF" .osm.pbf)}; MIN_CHECKPOINTS=0 ;;
esac
[[ "$NAME" =~ ^[A-Za-z0-9_-]+$ ]] || die "--name may only use letters, digits, - and _"

mkdir -p "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd)
in_work() { echo "/work/${1#"$WORK_DIR"/}"; }  # host path under $WORK_DIR -> container path
# Put an outside file under $WORK_DIR (hard link when possible) so the containers can see it.
import_file() {
  local src=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  [[ -f "$dest" ]] || ln "$src" "$dest" 2>/dev/null || cp "$src" "$dest"
}

MEM_GIB=$(host_mem_gib)
CPUS=$(host_cpus)
PT_MEMORY=${PT_MEMORY:-$(( MEM_GIB * 85 / 100 ))g}
PT_XMX=${PT_XMX:-$(( MEM_GIB * 40 / 100 ))g}  # the rest stays free for the page cache (mmap node map)
PT_CPUS=${PT_CPUS:-$CPUS}
PT_TIMEOUT=${PT_TIMEOUT:-14400}
CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAGE=$(mktemp -d "$WORK_DIR/.stage-XXXXXX")  # parts until the build id is known
PARTS=$STAGE/parts
mkdir -p "$PARTS" "$STAGE/logs"
# A run that stops before it has a build id keeps its logs under builds/failed-<time>.
trap '[[ -d "$STAGE" ]] && mkdir -p "$WORK_DIR/builds" && mv "$STAGE" "$WORK_DIR/builds/failed-$(date -u +%Y%m%dT%H%M%SZ)"' EXIT
kv() { printf '%s=%s\n' "$1" "$2" >>"$PARTS/build.kv"; }
timed() {  # timed NAME FUNCTION...: run and record the duration
  local name=$1 t0
  shift
  t0=$(date +%s)
  log "== $name"
  "$@"
  kv "time_$name" $(( $(date +%s) - t0 ))
  log "   $name done in $(( $(date +%s) - t0 )) s; free disk $(df -h "$WORK_DIR" | awk 'NR==2 {print $4}')"
}

planetiler() {  # planetiler LOG ARGS...: run the pinned image with the configured limits
  local logfile=$1
  shift
  docker run --rm "${DOCKER_USER[@]}" --memory "$PT_MEMORY" --cpus "$PT_CPUS" -e JAVA_TOOL_OPTIONS="-Xmx$PT_XMX" \
    -v "$WORK_DIR:/work" -v "$REPO_DIR/schema:/schema:ro" -w /work \
    --entrypoint timeout "$PLANETILER_IMAGE" "$PT_TIMEOUT" \
    java -cp @/app/jib-classpath-file com.onthegomap.planetiler.Main "$@" >"$logfile" 2>&1
}

# 1. Rule tests. planetiler's validator feeds synthetic features without an OSM type, so the
# id expressions (checked on real output in step 7) are left out of the copy it tests.
rule_tests() {
  local dir=$STAGE/rules-test
  mkdir -p "$dir"
  grep -v 'id: \*osm_id' "$REPO_DIR/schema/meshwish-osm.yml" >"$dir/meshwish-osm.yml"
  cp "$REPO_DIR/schema/meshwish-osm.spec.yml" "$dir/"
  # verify-custom exits 0 even when examples fail: read its summary line ("19 passed" when all pass)
  planetiler "$STAGE/logs/rule-tests.log" verify-custom --schema="$(in_work "$dir")/meshwish-osm.yml" || true
  local summary
  summary=$(tr -d '\033' <"$STAGE/logs/rule-tests.log" | sed 's/\[[0-9;]*m//g' | grep -aE '[0-9]+ (passed|failed)' | tail -1)
  [[ "$summary" =~ ^[1-9][0-9]*\ passed$ ]] || die "rule tests: ${summary:-no result} (log: $STAGE/logs/rule-tests.log)"
  log "rule tests: $summary"
}

# 2. OSM input.
osm_input() {
  local md5_url="" data_url="" file dest
  case $MODE in
    planet)
      if [[ "$PLANET" == latest ]]; then
        # newest week the mirror already has (mirrors trail the origin by up to a day)
        PLANET=$(curl -fsS -A "$USER_AGENT" "$PLANET_MIRROR/" | grep -o 'planet-[0-9]\{6\}\.osm\.pbf\.md5' |
                 sed 's/planet-\([0-9]*\).*/\1/' | sort -u | tail -1 || true)
        [[ -n "$PLANET" ]] || die "could not find the newest planet file at $PLANET_MIRROR/"
      fi
      file=planet-$PLANET.osm.pbf
      dest=$WORK_DIR/downloads/planet/$file
      md5_url=$PLANET_ORIGIN/$file.md5 data_url=$PLANET_MIRROR/$file ;;
    region)
      file=${REGION##*/}-latest.osm.pbf
      dest=$WORK_DIR/downloads/geofabrik/$REGION/$file
      md5_url=$GEOFABRIK/$REGION-latest.osm.pbf.md5 data_url=$GEOFABRIK/$REGION-latest.osm.pbf ;;
    file)
      file=$(basename "$PBF")
      dest=$WORK_DIR/downloads/local/$file
      import_file "$PBF" "$dest"
      [[ -f "$PBF.md5" ]] && import_file "$PBF.md5" "$dest.md5" ;;
  esac
  # The md5 comes from the origin, not the mirror, so a bad mirror cannot vouch for itself.
  # Exception: Geofabrik hands its largest extracts (europe, ...) to a mirror by redirect and
  # keeps their md5 only there.
  if [[ "$MODE" == region && ! -f "$dest.md5" ]]; then
    local moved
    moved=$(curl -sSI -A "$USER_AGENT" -o /dev/null -w '%{redirect_url}' "$data_url" || true)
    if [[ -n "$moved" ]]; then
      log "$data_url is served from $moved; taking the md5 from there"
      md5_url=$moved.md5 data_url=$moved
    fi
  fi
  if [[ -n "$md5_url" && ! -f "$dest.md5" ]]; then fetch "$md5_url" "$dest.md5" || die "no checksum at $md5_url"; fi
  kv osm_md5_url "$md5_url"
  if [[ "$DRY_RUN" == 1 ]]; then
    local size=""
    [[ -n "$data_url" ]] && size=$(curl -fsSI -L -A "$USER_AGENT" "$data_url" | tr -d '\r' |
                                   sed -n 's/^[Cc]ontent-[Ll]ength: //p' | tail -1 || true)
    log "dry run: would use $file (${size:-?} bytes) from ${data_url:-$PBF}, md5 $(cut -d' ' -f1 "$dest.md5" 2>/dev/null)"
    rm -rf "$STAGE"
    exit 0
  fi
  local want="" verified=0
  [[ -f "$dest.md5" ]] && want=$(cut -d' ' -f1 "$dest.md5")
  if [[ -f "$dest" && -n "$want" && "$(md5_of "$dest")" == "$want" ]]; then
    log "reusing $dest (md5 ok)"
    verified=1
  elif [[ -n "$data_url" ]]; then
    rm -f "$dest"
    fetch "$data_url" "$dest" || die "download of $data_url failed"
    [[ "$(md5_of "$dest")" == "$want" ]] || { rm -f "$dest"; die "md5 mismatch for $data_url"; }
    verified=1
  elif [[ -n "$want" ]]; then
    die "md5 mismatch for $PBF"
  fi
  OSM_FILE=$dest
  kv osm_url "$data_url"
  kv osm_file "$file"
  kv osm_bytes "$(file_size "$dest")"
  kv osm_md5 "$want"
  kv osm_md5_verified "$verified"
  tools osmium fileinfo -j --no-progress "$(in_work "$dest")" >"$PARTS/osm_header.json"
}

# 3. Tag filter (and bbox cut).
osm_filter() {
  local out=$BUILD_DIR/input/needed.osm.pbf
  mkdir -p "$BUILD_DIR/input"
  # shellcheck disable=SC2086  # the filter list is word-split on purpose
  tools osmium tags-filter --no-progress -O "$(in_work "$OSM_FILE")" $OSMIUM_FILTER \
    -f pbf,add_metadata=false -o "$(in_work "$out")"
  if [[ -n "$BBOX" ]]; then
    tools osmium extract --no-progress -O -b "$BBOX" --strategy smart --set-bounds \
      -f pbf,add_metadata=false -o "$(in_work "$out.cut")" "$(in_work "$out")"
    mv "$out.cut" "$out"
  fi
  NEEDED=$out
  kv needed_bytes "$(file_size "$out")"
  tools osmium fileinfo -e -j --no-progress "$(in_work "$out")" >"$PARTS/needed_info.json"
  if [[ "$DELETE_INPUT" == 1 && "$MODE" != file ]]; then
    log "deleting $OSM_FILE (md5 kept)"
    rm -f "$OSM_FILE"
  fi
}

# 4. Water polygons.
water_polygons() {
  local zip status last_modified=""
  if [[ -n "$OCEAN_ZIP" ]]; then
    zip=$BUILD_DIR/input/ocean/$(basename "$OCEAN_ZIP")
    import_file "$OCEAN_ZIP" "$zip"
    status=given
  else
    last_modified=$(curl -fsSI -A "$USER_AGENT" "$OSMDATA_URL" | tr -d '\r' | sed -n 's/^[Ll]ast-[Mm]odified: //p')
    local day
    day=$(date -u -d "$last_modified" +%Y%m%d 2>/dev/null || date -u -j -f '%a, %d %b %Y %T GMT' "$last_modified" +%Y%m%d 2>/dev/null || date -u +%Y%m%d)
    zip=$WORK_DIR/downloads/osmdata/$day/water-polygons-split-4326.zip
    [[ -f "$zip" ]] || fetch "$OSMDATA_URL" "$zip" || die "download of $OSMDATA_URL failed"
    status=accepted
  fi
  py osmdata_tool.py stats "$(in_work "$zip")" "$(in_work "$PARTS/osmdata_stats.json")" >/dev/null
  local prev_zip=""
  if [[ -n "$PREV_OSMDATA" ]]; then
    [[ -f "$PREV_OSMDATA/stats.json" ]] || die "no stats.json in $PREV_OSMDATA"
    cp "$PREV_OSMDATA/stats.json" "$PARTS/osmdata_prev_stats.json"
    local prev_name
    prev_name=$(sed -n 's/^ *"file": "\(.*\)",$/\1/p' "$PREV_OSMDATA/stats.json" | head -1)
    [[ -n "$prev_name" && -f "$PREV_OSMDATA/$prev_name" ]] && prev_zip=$PREV_OSMDATA/$prev_name
    local planet_ts
    planet_ts=$(sed -n 's/.*"osmosis_replication_timestamp": "\([^"]*\)".*/\1/p' "$PARTS/osm_header.json")
    if ! py osmdata_tool.py compare "$(in_work "$PARTS/osmdata_stats.json")" "$(in_work "$PARTS/osmdata_prev_stats.json")" \
        ${planet_ts:+--planet-date "$planet_ts"} --out "$(in_work "$PARTS/osmdata_check.json")" >&2; then
      [[ -n "$prev_zip" ]] || die "water polygons failed the comparison and the previous zip is missing"
      log "water polygons failed the comparison; using the previous accepted file $prev_name"
      local keep=$BUILD_DIR/input/ocean/$prev_name
      import_file "$prev_zip" "$keep"
      zip=$keep
      cp "$PARTS/osmdata_prev_stats.json" "$PARTS/osmdata_stats.json"
      status=fallback_previous
    fi
  elif [[ "$status" == accepted ]]; then
    py osmdata_tool.py sanity "$(in_work "$PARTS/osmdata_stats.json")" --out "$(in_work "$PARTS/osmdata_check.json")" >&2 ||
      die "water polygons look broken and there is no previous file to fall back to"
    status=first_build
  fi
  OCEAN=$zip
  kv osmdata_url "$([[ -z "$OCEAN_ZIP" ]] && echo "$OSMDATA_URL")"
  kv osmdata_last_modified "$last_modified"
  kv osmdata_status "$status"
  kv osmdata_zip "${zip#"$WORK_DIR"/}"
}

# 5. planetiler.
tiles() {
  local bounds
  if [[ "$MODE" == planet ]]; then
    bounds=world
  elif [[ -n "$BBOX" ]]; then
    bounds=$BBOX
  else
    bounds=$(tr -d ' \n' <"$PARTS/osm_header.json" | sed -n 's/.*"boxes":\[\[\([^]]*\)\]\].*/\1/p')
    [[ -n "$bounds" ]] || die "the OSM file has no bounding box; pass --bbox"
  fi
  rm -rf "$BUILD_DIR/tmp"
  PT_ARGS="generate-custom --schema=/schema/meshwish-osm.yml --osm_path=$(in_work "$NEEDED") --water_path=$(in_work "$OCEAN") --output=$(in_work "$BUILD_DIR/raw.pmtiles") --tmpdir=$(in_work "$BUILD_DIR/tmp") --bounds=$bounds --output_layerstats --layer_stats=$(in_work "$BUILD_DIR/layerstats.tsv.gz") --nodemap_type=sparsearray --nodemap_storage=mmap --threads=$PT_CPUS ${PT_EXTRA_ARGS:-}"
  # shellcheck disable=SC2086
  planetiler "$BUILD_DIR/logs/planetiler.log" $PT_ARGS --http_user_agent="$USER_AGENT" ||
    die "planetiler failed (log: $BUILD_DIR/logs/planetiler.log)"
  rm -rf "$BUILD_DIR/tmp"
  kv planetiler_args "$PT_ARGS"
}

# 6. Metadata.
metadata() {
  local pairs=()
  py pmtiles_tool.py info "$(in_work "$BUILD_DIR/raw.pmtiles")" >"$PARTS/raw_metadata.json"
  while IFS= read -r line; do pairs+=("$line"); done < <(py manifest.py metadata "$(in_work "$PARTS")")
  [[ ${#pairs[@]} -gt 0 ]] || die "no metadata to add"
  py pmtiles_tool.py set-metadata "$(in_work "$BUILD_DIR/raw.pmtiles")" "$(in_work "$OUTPUT")" "${pairs[@]}" >/dev/null
  rm -f "$BUILD_DIR/raw.pmtiles"
}

# 7. Checks.
checks() {
  local args=(--out "$(in_work "$PARTS/verify.json")" --layerstats "$(in_work "$BUILD_DIR/layerstats.tsv.gz")"
              --checkpoints /schema/checkpoints.json --min-checkpoints "$MIN_CHECKPOINTS")
  [[ -n "$REQUIRE_LAYERS" ]] && args+=(--require-layers "$REQUIRE_LAYERS")
  if [[ -n "$PREV_MANIFEST" ]]; then
    cp "$PREV_MANIFEST" "$PARTS/prev_manifest.json"
    args+=(--prev-manifest "$(in_work "$PARTS/prev_manifest.json")")
  fi
  # distinct ids per layer need every tile decoded: fine for test areas, too slow for a planet
  [[ $(file_size "$OUTPUT") -lt 300000000 ]] && args+=(--decode-all --id-sample-every 1)
  py pmtiles_tool.py verify "$(in_work "$OUTPUT")" "${args[@]}" >&2 || CHECKS_FAILED=1
}

tools_image
timed rule_tests rule_tests
timed input osm_input

PLANET_DATE=$(sed -n 's/.*"osmosis_replication_timestamp": "\([0-9]*\)-\([0-9]*\)-\([0-9]*\)T.*/\1\2\3/p' "$PARTS/osm_header.json")
[[ -n "$PLANET_DATE" ]] || PLANET_DATE=$(date -u +%Y%m%d)
BUILD_ID=$PLANET_DATE-$NAME-$(date -u +%Y%m%dT%H%MZ)
BUILD_DIR=$WORK_DIR/builds/$BUILD_ID
mkdir -p "$WORK_DIR/builds"
mv "$STAGE" "$BUILD_DIR"
PARTS=$BUILD_DIR/parts
OUTPUT=$BUILD_DIR/meshwish-osm.pmtiles
CHECKS_FAILED=0
log "build $BUILD_ID in $BUILD_DIR"
kv build_id "$BUILD_ID"
kv created_at "$CREATED_AT"
kv mode "$MODE"
kv scope "$NAME"
kv region "$REGION"
kv bbox "$BBOX"
kv method_url "${METHOD_URL:-}"

timed filter osm_filter
timed osmdata water_polygons
timed planetiler tiles
timed metadata metadata
timed checks checks

commit=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)
[[ -n "$commit" && -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]] && commit="$commit-dirty"
kv repo_commit "$commit"
kv tools_version "$LAYER_TOOLS_VERSION"
kv schema_sha256 "$(sha256_of "$REPO_DIR/schema/meshwish-osm.yml")"
kv spec_sha256 "$(sha256_of "$REPO_DIR/schema/meshwish-osm.spec.yml")"
kv osmium_filter "$OSMIUM_FILTER"
kv planetiler_image "$PLANETILER_IMAGE"
kv tools_base_image "$TOOLS_BASE_IMAGE"
kv tools_image_id "$(docker image inspect -f '{{.Id}}' "$TOOLS_IMAGE")"
# shellcheck disable=SC2016  # dpkg-query format fields, not shell variables
kv packages "$(tools dpkg-query -W -f '${Package}=${Version};' osmium-tool python3 python3-numpy)"
kv output_file "$(basename "$OUTPUT")"
kv output_bytes "$(file_size "$OUTPUT")"
kv output_sha256 "$(sha256_of "$OUTPUT")"
kv pt_memory "$PT_MEMORY"
kv pt_xmx "$PT_XMX"
kv pt_cpus "$PT_CPUS"
kv host_cpus "$CPUS"
kv host_mem_gib "$MEM_GIB"
py manifest.py assemble "$(in_work "$PARTS")" "$(in_work "$BUILD_DIR/manifest.json")"
log "manifest: $BUILD_DIR/manifest.json"
[[ "$CHECKS_FAILED" == 0 ]] || die "checks failed; see $PARTS/verify.json (not for upload)"
echo "$BUILD_DIR"
