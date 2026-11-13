#!/usr/bin/env bash
# Fetch what the next build compares with: the current build's manifest and the last accepted
# water polygons, as named by latest.json under $OSM_S3_URI (see upload.sh).
#
#   scripts/fetch-previous.sh DIR
#
# Writes DIR/latest.json, DIR/prev-manifest.json and DIR/osmdata/{stats.json,<zip>}, then prints
# the build.sh options that use them (--prev-manifest ... --prev-osmdata ...). Prints nothing
# when there is no latest.json yet (the first build). Same environment as upload.sh.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

[[ $# -eq 1 ]] || die "usage: fetch-previous.sh DIR"
for v in OSM_S3_URI AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!v:-}" ]] || die "$v is not set"
done
split_s3_uri "$OSM_S3_URI"
mkdir -p "$1/osmdata"
WORK_DIR=$(cd "$1" && pwd)
tools_image
aws_config "$WORK_DIR"
aws() { aws_cli "$WORK_DIR" "$@"; }
s3() { echo "s3://$S3_BUCKET/$1"; }
get() { py latest.py get /work/latest.json "$1"; }

if ! aws s3 cp "$(s3 "${S3_PREFIX:+$S3_PREFIX/}latest.json")" /work/latest.json --only-show-errors 2>/dev/null; then
  log "no latest.json under $OSM_S3_URI: first build"
  exit 0
fi
opts=()
manifest=$(get current.manifest)
if [[ -n "$manifest" ]]; then
  aws s3 cp "$(s3 "$manifest")" /work/prev-manifest.json --only-show-errors
  opts+=(--prev-manifest "$WORK_DIR/prev-manifest.json")
fi
stats=$(get osmdata.stats)
zip=$(get osmdata.zip)
if [[ -n "$stats" && -n "$zip" ]]; then
  aws s3 cp "$(s3 "$stats")" /work/osmdata/stats.json --only-show-errors
  aws s3 cp "$(s3 "$zip")" "/work/osmdata/$(basename "$zip")" --only-show-errors
  [[ "$(sha256_of "$WORK_DIR/osmdata/$(basename "$zip")")" == "$(get osmdata.sha256)" ]] ||
    die "previous water polygon zip does not match its sha256"
  opts+=(--prev-osmdata "$WORK_DIR/osmdata")
fi
rm -f "$WORK_DIR/.aws-config"
log "previous build: $(get current.build_id)"
echo ${opts[@]+"${opts[@]}"}
