#!/usr/bin/env bash
# Upload a finished build to S3-compatible storage (Cloudflare R2) and point latest.json at it.
#
#   scripts/upload.sh BUILD_DIR [--no-latest] [--prune]
#
# Layout under $OSM_S3_URI (s3://bucket/prefix):
#   builds/<build_id>/meshwish-osm.pmtiles   the archive; multipart upload, x-amz-meta-sha256
#   builds/<build_id>/manifest.json          what was built from what (see README)
#   osmdata/<date>/water-polygons-split-4326.zip and stats.json
#                                            the last accepted water polygons, which the next
#                                            build compares with and falls back to
#   latest.json                              {"current", "previous", "osmdata"}; see scripts/tools/latest.py
#
# Order matters: the archive and manifest go up first and are checked (size and sha256 metadata
# from HEAD, first 127 bytes read back); latest.json is replaced last, in one PUT, so readers
# following it never see a half-uploaded build. The build that was current becomes "previous"
# and stays in place for rollback. --no-latest uploads only builds/<id>/ (test runs);
# --prune afterwards deletes every other build and all but the newest two osmdata copies.
#
# Environment: OSM_S3_URI, OSM_S3_ENDPOINT (R2: https://<account id>.r2.cloudflarestorage.com),
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY (an R2 token with Object Read & Write on this bucket
# only), AWS_DEFAULT_REGION (default auto). S3_CHUNK_MB (256) and S3_CONCURRENCY (8) tune the
# multipart upload.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

BUILD_DIR="" SET_LATEST=1 PRUNE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --no-latest) SET_LATEST=0; shift ;;
    --prune) PRUNE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown argument $1" ;;
    *) BUILD_DIR=$1; shift ;;
  esac
done
[[ -n "$BUILD_DIR" && -f "$BUILD_DIR/manifest.json" ]] || die "usage: upload.sh BUILD_DIR (with manifest.json)"
for v in OSM_S3_URI AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!v:-}" ]] || die "$v is not set"
done
split_s3_uri "$OSM_S3_URI"
BUILD_DIR=$(cd "$BUILD_DIR" && pwd)
WORK_DIR=$(cd "$BUILD_DIR/../.." && pwd)  # builds/<id> lives in the build's work dir
tools_image
STAGE=$BUILD_DIR/.upload
rm -rf "$STAGE"
mkdir -p "$STAGE"
aws_config "$WORK_DIR"
mf() { py latest.py get "$(in_work "$BUILD_DIR/manifest.json")" "$1"; }
in_work() { echo "/work/${1#"$WORK_DIR"/}"; }
key() { echo "${S3_PREFIX:+$S3_PREFIX/}$1"; }
s3() { echo "s3://$S3_BUCKET/$(key "$1")"; }
aws() { aws_cli "$WORK_DIR" "$@"; }

[[ "$(mf checks.failures)" == "[]" ]] || die "this build failed its checks: $(mf checks.failures)"
BUILD_ID=$(mf build_id)
FILE=$(mf output.file)
SHA=$(mf output.sha256)
BYTES=$(mf output.bytes)
[[ "$(file_size "$BUILD_DIR/$FILE")" == "$BYTES" ]] || die "$FILE size differs from the manifest"
log "checking sha256 of $FILE"
[[ "$(sha256_of "$BUILD_DIR/$FILE")" == "$SHA" ]] || die "$FILE sha256 differs from the manifest"

# 1. Archive and manifest.
ARCHIVE_KEY=$(key "builds/$BUILD_ID/$FILE")
log "upload $FILE ($BYTES bytes) to $(s3 "builds/$BUILD_ID/$FILE")"
aws s3 cp "$(in_work "$BUILD_DIR/$FILE")" "$(s3 "builds/$BUILD_ID/$FILE")" --only-show-errors \
  --metadata "sha256=$SHA,build_id=$BUILD_ID" --content-type application/vnd.pmtiles
size=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$ARCHIVE_KEY" --query ContentLength --output text)
meta=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$ARCHIVE_KEY" --query Metadata.sha256 --output text)
[[ "$size" == "$BYTES" && "$meta" == "$SHA" ]] || die "uploaded archive does not match (size $size, sha256 $meta)"
aws s3api get-object --bucket "$S3_BUCKET" --key "$ARCHIVE_KEY" --range bytes=0-126 "$(in_work "$STAGE/head.bin")" >/dev/null
head -c 127 "$BUILD_DIR/$FILE" | cmp -s - "$STAGE/head.bin" || die "header read back from storage differs"
aws s3 cp "$(in_work "$BUILD_DIR/manifest.json")" "$(s3 "builds/$BUILD_ID/manifest.json")" --only-show-errors \
  --content-type application/json
log "archive and manifest uploaded and checked"

# 2. Water polygons this build accepted become the reference for the next one.
status=$(mf inputs.osmdata.status)
if [[ "$status" == accepted || "$status" == first_build ]]; then
  zip_rel=$(sed -n 's/^osmdata_zip=//p' "$BUILD_DIR/parts/build.kv")
  day=$(mf inputs.osmdata.stats.data_date | cut -c1-10)
  zip_name=$(mf inputs.osmdata.stats.file)
  if [[ -f "$WORK_DIR/$zip_rel" && -n "$day" ]]; then
    aws s3 cp "/work/$zip_rel" "$(s3 "osmdata/$day/$zip_name")" --only-show-errors
    aws s3 cp "$(in_work "$BUILD_DIR/parts/osmdata_stats.json")" "$(s3 "osmdata/$day/stats.json")" --only-show-errors \
      --content-type application/json
    log "water polygons of $day uploaded"
  else
    log "WARNING: accepted water polygon zip not found ($zip_rel); latest.json keeps the old reference"
    status=missing
  fi
fi

# 3. latest.json, last.
if [[ "$SET_LATEST" == 1 ]]; then
  old=-
  if aws s3 cp "$(s3 latest.json)" "$(in_work "$STAGE/old-latest.json")" --only-show-errors 2>/dev/null; then
    old=$(in_work "$STAGE/old-latest.json")
  else
    log "no latest.json yet; this is the first build"
  fi
  extra=()
  [[ "$status" == accepted || "$status" == first_build ]] || extra=(--no-osmdata)
  py latest.py next "$old" "$(in_work "$BUILD_DIR/manifest.json")" "$S3_PREFIX" "$(in_work "$STAGE/latest.json")" \
    ${extra[@]+"${extra[@]}"} >/dev/null
  aws s3 cp "$(in_work "$STAGE/latest.json")" "$(s3 latest.json)" --only-show-errors --content-type application/json \
    --cache-control no-cache
  log "latest.json now points at $BUILD_ID"
fi

# 4. Optional pruning: keep current and previous builds, and the newest two osmdata copies.
if [[ "$PRUNE" == 1 ]]; then
  aws s3 cp "$(s3 latest.json)" "$(in_work "$STAGE/latest-now.json")" --only-show-errors
  keep=" $(py latest.py keep "$(in_work "$STAGE/latest-now.json")" | tr '\n' ' ') "
  aws s3 ls "$(s3 builds/)" | sed -n 's#^ *PRE \(.*\)/$#\1#p' | while read -r id; do
    [[ "$keep" == *" $id "* ]] && continue
    log "prune build $id"
    aws s3 rm --recursive --only-show-errors "$(s3 "builds/$id/")"
  done
  aws s3 ls "$(s3 osmdata/)" | sed -n 's#^ *PRE \(.*\)/$#\1#p' | sort -r | tail -n +3 | while read -r day; do
    log "prune osmdata $day"
    aws s3 rm --recursive --only-show-errors "$(s3 "osmdata/$day/")"
  done
fi
rm -rf "$STAGE" "$WORK_DIR/.aws-config"
log "done: $(s3 "builds/$BUILD_ID/")"
