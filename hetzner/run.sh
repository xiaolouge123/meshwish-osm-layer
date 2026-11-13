#!/bin/bash
# The build on the Hetzner server, started by bootstrap.sh from a checkout of REPO_REF: fetch
# the previous build's manifest and water polygons, build, upload, and upload the logs to
# $OSM_S3_URI/logs/<time>-<ok|failed>/ whatever happened. Environment from /etc/meshwish-osm/env.
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=scripts/lib.sh
. "$REPO/scripts/lib.sh"
WORK=/var/lib/meshwish-osm
mkdir -p "$WORK"
STAMP=$(date -u +%Y%m%dT%H%MZ)
STATUS=failed
BUILD_DIR=""
METHOD_URL="${REPO_URL%.git}/tree/$(git -C "$REPO" rev-parse HEAD)"
export METHOD_URL

upload_logs() {
  local dir=$WORK/logs-$STAMP
  mkdir -p "$dir"
  cp /var/log/meshwish-osm.log "$dir/" 2>/dev/null
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    cp -r "$BUILD_DIR/logs" "$BUILD_DIR/parts" "$dir/" 2>/dev/null
    cp "$BUILD_DIR/manifest.json" "$dir/" 2>/dev/null
  fi
  split_s3_uri "$OSM_S3_URI"
  aws_cli "$WORK" s3 cp --recursive --only-show-errors "/work/logs-$STAMP" \
    "s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}logs/$STAMP-$STATUS/" || log "log upload failed"
}
trap upload_logs EXIT

log "run on $(hostname): $(host_cpus) cpus, $(host_mem_gib) GiB, $(df -h "$WORK" | awk 'NR==2 {print $4}') free"
prev=$("$REPO/scripts/fetch-previous.sh" "$WORK/prev") || exit 1
# shellcheck disable=SC2086  # BUILD_ARGS and prev are option lists
out=$("$REPO/scripts/build.sh" $BUILD_ARGS $prev --work "$WORK/work" --delete-input)
rc=$?
BUILD_DIR=$(printf '%s\n' "$out" | tail -1)
if [[ $rc != 0 || ! -f "$BUILD_DIR/manifest.json" ]]; then
  # shellcheck disable=SC2012  # build ids have no odd characters
  BUILD_DIR=$(ls -dt "$WORK"/work/builds/*/ 2>/dev/null | head -1)  # newest, for the logs
  BUILD_DIR=${BUILD_DIR%/}
  exit 1
fi
# shellcheck disable=SC2086
"$REPO/scripts/upload.sh" "$BUILD_DIR" $UPLOAD_ARGS || exit 1
STATUS=ok
log "build and upload finished: $BUILD_DIR"
