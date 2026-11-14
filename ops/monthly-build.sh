#!/usr/bin/env bash
# The monthly planet build on a long-lived server of ours, started by meshwish-osm-monthly.service
# from its timer. Installed as /usr/local/sbin/meshwish-osm-monthly (ops/README.md); it keeps
# its own checkout of this repository under $OSM_BASE and runs the scripts of that checkout.
#
#   meshwish-osm-monthly [--dry-run] [--force]
#
# One run:
#   1. lock: $OSM_BASE/monthly.lock (flock); a second run while one is going fails at once;
#   2. checkout: fetch $OSM_REPO_URL into $OSM_BASE/repo and check out the tag $OSM_REPO_REF names
#      (required: a reviewed vX.Y.Z; "latest" follows the newest vX.Y.Z tag on origin/main); a tag
#      whose commit changed since a run used it is refused;
#   3. previous build: scripts/fetch-previous.sh (latest.json, the current manifest and the last
#      accepted water polygons);
#   4. decide: the newest planet file on $PLANET_MIRROR against the one the current build's
#      manifest names (by date when it names none). The same planet (or an older one) is a skip,
#      unless --force or the file
#      $OSM_BASE/force-next-run (removed once a build it forced is uploaded);
#   5. clean: earlier builds keep only their manifests and logs, stale downloads go, then at
#      least $OSM_MIN_FREE_GB must be free (the planet peaked at 120 GB of work files);
#   6. build: scripts/build.sh --planet <that planet> --delete-input. Its checks decide: a build
#      with failures is never uploaded;
#   7. upload: scripts/upload.sh --prune: archive and manifest first, latest.json last; then
#      every build but current and previous is deleted from the bucket;
#   8. report, whatever happened: the log goes to the journal and $OSM_BASE/logs/, a build's
#      logs to the bucket's logs/<time>-<ok|failed>/ (as hetzner/run.sh does), the outcome to
#      $OSM_BASE/last-run.json, and to NOTIFY_WEBHOOK_URL when set.
# --dry-run stops after step 4 with build.sh --dry-run: nothing is built, uploaded or deleted.
# Exit status: 0 built and uploaded, skipped, or dry run; 1 failed.
#
# Host: bash 4.4+, git, curl, docker, python3, flock and timeout (util-linux, coreutils).
# Environment (systemd's EnvironmentFile, see monthly-build.env.example):
#   OSM_S3_URI, OSM_S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#                       storage, as for scripts/upload.sh
#   OSM_BASE            checkout, work files, logs (default /srv/osm-layer/monthly)
#   OSM_REPO_URL        this repository (default the public one); OSM_REPO_REF pins a tag
#   OSM_MIN_FREE_GB     free disk needed before a build (160)
#   OSM_BUILD_TIMEOUT, OSM_UPLOAD_TIMEOUT   seconds (18000, 7200)
#   OSM_DOCKER_SLICE    systemd slice for the containers (meshwish-osm.slice; empty: docker's own)
#   PLANET_MIRROR, PT_MEMORY, PT_XMX, PT_CPUS, TOOLS_MEMORY, TOOLS_CPUS   as for build.sh
#   NOTIFY_WEBHOOK_URL  POST the outcome here; NOTIFY_WEBHOOK_FORMAT slack|discord|feishu
#                       (body {"text"}, {"content"}, Feishu/Lark's text message); NOTIFY_ON
#                       failure (default), always or never
set -euo pipefail

DRY_RUN=0 FORCE=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done

OSM_BASE=${OSM_BASE:-/srv/osm-layer/monthly}
OSM_REPO_URL=${OSM_REPO_URL:-https://github.com/xiaolouge123/meshwish-osm-layer.git}
OSM_REPO_REF=${OSM_REPO_REF:-}
OSM_MIN_FREE_GB=${OSM_MIN_FREE_GB:-160}
OSM_BUILD_TIMEOUT=${OSM_BUILD_TIMEOUT:-18000}
OSM_UPLOAD_TIMEOUT=${OSM_UPLOAD_TIMEOUT:-7200}
OSM_DOCKER_SLICE=${OSM_DOCKER_SLICE-meshwish-osm.slice}
NOTIFY_ON=${NOTIFY_ON:-failure}
NOTIFY_WEBHOOK_FORMAT=${NOTIFY_WEBHOOK_FORMAT:-slack}
export PLANET_MIRROR=${PLANET_MIRROR:-https://ftp.fau.de/osm-planet/pbf}
# The limits the planet was built with on 16 threads / 61 GiB: 61 min, 18 GB of RAM in use
# plus page cache for the 50 GB node map. Lower them when the host has other work (ops/README.md).
export TOOLS_MEMORY=${TOOLS_MEMORY:-16g} TOOLS_CPUS=${TOOLS_CPUS:-16}
export PT_MEMORY=${PT_MEMORY:-56g} PT_XMX=${PT_XMX:-20g} PT_CPUS=${PT_CPUS:-16}

REPO=$OSM_BASE/repo WORK=$OSM_BASE/work PREV=$OSM_BASE/prev LOGS=$OSM_BASE/logs
export HOME=$OSM_BASE/home  # docker and git keep their settings here
STAMP=$(date -u +%Y%m%dT%H%M%SZ)  # also labels this run's containers
STARTED=$(date +%s)
LOG=$LOGS/monthly-$STAMP.log
mkdir -p "$HOME" "$WORK" "$LOGS"

# Everything to the journal (stdout) and to the run's log file. tee ignores SIGTERM, so a stop
# (systemctl stop, the unit's timeout) still logs what finish() does; finish() waits for it.
exec > >(trap '' TERM INT; exec tee -a "$LOG") 2>&1
TEE_PID=$!

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
fail() { say "ERROR: $*"; exit 1; }

STATUS=failed TAG="" COMMIT="" PLANET="" BUILD_DIR="" BUILT=0 LOCKED=0
# python3 -I: JSON in and out without quoting surprises. A null (latest.py prints None) is empty.
json_get() {
  local value
  value=$(python3 -I "$REPO/scripts/tools/latest.py" get "$1" "$2")
  [[ "$value" == None ]] && value=""
  printf '%s\n' "$value"
}

stop_containers() {  # containers this run started, should any outlive their docker client
  local ids
  ids=$(docker ps -q --filter "label=meshwish-osm-run=$STAMP" 2>/dev/null || true)
  [[ -z "$ids" ]] && return 0
  say "stopping containers left running: $(echo "$ids" | tr '\n' ' ')"
  # shellcheck disable=SC2086  # container ids
  docker kill $ids >/dev/null 2>&1 || true
}

upload_logs() {  # the build's logs next to the builds, as hetzner/run.sh does
  local dir=$OSM_BASE/upload-logs/$STAMP
  rm -rf "$OSM_BASE/upload-logs"
  mkdir -p "$dir"
  cp "$LOG" "$dir/" 2>/dev/null
  if [[ -n "$BUILD_DIR" && -d "$BUILD_DIR" ]]; then
    cp -r "$BUILD_DIR/logs" "$BUILD_DIR/parts" "$dir/" 2>/dev/null
    cp "$BUILD_DIR/manifest.json" "$dir/" 2>/dev/null
  fi
  (
    # shellcheck source=scripts/lib.sh
    . "$REPO/scripts/lib.sh"
    split_s3_uri "$OSM_S3_URI"
    aws_cli "$OSM_BASE/upload-logs" s3 cp --recursive --only-show-errors "/work/$STAMP" \
      "s3://$S3_BUCKET/${S3_PREFIX:+$S3_PREFIX/}logs/$STAMP-$1/"
  ) || say "log upload failed"
  rm -rf "$OSM_BASE/upload-logs"
}

notify() {
  [[ -n "${NOTIFY_WEBHOOK_URL:-}" ]] || return 0
  case $NOTIFY_ON in
    always) ;;
    failure) [[ "$STATUS" == failed || "$STATUS" == locked ]] || return 0 ;;
    *) return 0 ;;
  esac
  local text body
  text="meshwish OSM layer, monthly build on $(hostname): $STATUS"
  text+=$'\n'"tag ${TAG:-?} (${COMMIT:0:12}), planet ${PLANET:-?}, build ${BUILD_DIR##*/}, $(( ($(date +%s) - STARTED) / 60 )) min"
  text+=$'\n'"log: $LOG"
  [[ "$STATUS" == failed || "$STATUS" == locked ]] && text+=$'\n'"$(tail -n 15 "$LOG" 2>/dev/null)"
  body=$(python3 -I -c 'import json, sys
fmt, text = sys.argv[1], sys.argv[2]
print(json.dumps({"discord": {"content": text[:1900]},
                  "feishu": {"msg_type": "text", "content": {"text": text}}}.get(fmt, {"text": text})))' \
    "$NOTIFY_WEBHOOK_FORMAT" "$text")
  # The address (it carries the hook's token) and the body (log lines) off the command line, which
  # other users may read: the address as a curl config on a pipe, the body on stdin.
  curl -fsS -m 30 --retry 3 -K <(printf 'url = "%s"\n' "$NOTIFY_WEBHOOK_URL") -H 'Content-Type: application/json' \
    --data-binary @- <<<"$body" >/dev/null || say "notification failed"
}

finish() {
  local rc=$?
  set +e
  trap '' TERM INT
  [[ "$rc" != 0 && "$STATUS" != locked ]] && STATUS=failed
  [[ "$STATUS" == running ]] && STATUS=failed
  if [[ "$LOCKED" == 1 ]]; then
    stop_containers
    [[ "$BUILT" == 1 ]] && upload_logs "$([[ "$STATUS" == ok ]] && echo ok || echo failed)"
    # a dry run leaves the record of the last real run alone, whatever came of it
    [[ "$DRY_RUN" == 1 ]] || python3 -I -c 'import json, sys
*values, path = sys.argv[1:]
keys = ("status", "started", "finished", "tag", "commit", "planet", "build_id", "log")
with open(path, "w") as f:
    json.dump(dict(zip(keys, values)), f, indent=1)' \
      "$STATUS" "$STAMP" "$(date -u +%Y%m%dT%H%M%SZ)" "$TAG" "$COMMIT" "$PLANET" "${BUILD_DIR##*/}" "$LOG" \
      "$OSM_BASE/last-run.json"
    # the newest 24 run logs stay
    # shellcheck disable=SC2012  # our own file names
    ls -1t "$LOGS"/monthly-*.log 2>/dev/null | tail -n +25 | while read -r old; do rm -f "$old"; done
  fi
  notify
  say "finished: $STATUS"
  exec >&- 2>&-
  wait "$TEE_PID" 2>/dev/null
  [[ "$STATUS" == failed || "$STATUS" == locked ]] && exit 1
  exit 0
}
trap finish EXIT
trap 'say "stopped by SIGTERM"; exit 143' TERM
trap 'say "stopped by SIGINT"; exit 130' INT

# 1. Lock.
exec 9>"$OSM_BASE/monthly.lock"
if ! flock -n 9; then
  STATUS=locked
  fail "another run holds $OSM_BASE/monthly.lock"
fi
LOCKED=1
STATUS=running
say "monthly build on $(hostname): $(getconf _NPROCESSORS_ONLN) cpus, $(df -h "$OSM_BASE" | awk 'NR==2 {print $4}') free; dry run $DRY_RUN"

# 2. Checkout.
if [[ ! -d "$REPO/.git" ]]; then
  git clone -q "$OSM_REPO_URL" "$REPO"
fi
git -C "$REPO" remote set-url origin "$OSM_REPO_URL"
# --force: a tag moved upstream would otherwise stop this and every later run (git refuses to clobber it).
git -C "$REPO" fetch -q --force --tags --prune --prune-tags origin
# The code that runs here as a docker user with the bucket's key: a reviewed tag, pinned by hand.
TAG=$OSM_REPO_REF
[[ -n "$TAG" ]] || fail "OSM_REPO_REF is not set: pin a reviewed tag (vX.Y.Z), or \"latest\" to follow main's newest"
if [[ "$TAG" == latest ]]; then
  TAG=$(git -C "$REPO" tag -l 'v*' --merged origin/main --sort=v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' |
        tail -1 || true)
  [[ -n "$TAG" ]] || fail "no vX.Y.Z tag on origin/main of $OSM_REPO_URL"
fi
# A tag only: a branch name would resolve to the local branch of the first clone, never updated.
git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG^{commit}" >/dev/null ||
  fail "$TAG is not a tag of $OSM_REPO_URL (OSM_REPO_REF takes a tag, such as v0.1.3)"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || fail "$REPO has local changes; leaving it as it is"
COMMIT=$(git -C "$REPO" rev-parse "refs/tags/$TAG^{commit}")
# A tag is not moved: one that names another commit than when a run first used it is refused.
SEEN=$OSM_BASE/tags.seen
touch "$SEEN"
WAS=$(awk -v t="$TAG" '$1 == t {print $2}' "$SEEN")
[[ -z "$WAS" || "$WAS" == "$COMMIT" ]] || fail "$TAG was $WAS when a run used it and is $COMMIT now: refusing a moved tag"
[[ -n "$WAS" ]] || echo "$TAG $COMMIT" >>"$SEEN"
git -C "$REPO" checkout -q --detach "$COMMIT"
say "using $TAG ($COMMIT)"
if grep -q DOCKER_RUN_ARGS "$REPO/scripts/lib.sh"; then
  DOCKER_RUN_ARGS="--label=meshwish-osm-run=$STAMP${OSM_DOCKER_SLICE:+ --cgroup-parent=$OSM_DOCKER_SLICE}"
  export DOCKER_RUN_ARGS
else
  say "WARNING: $TAG predates DOCKER_RUN_ARGS: its containers run outside $OSM_DOCKER_SLICE, unlabelled"
fi
# The metadata links the layer to the code that made it (ODbL §4.6b).
export METHOD_URL="${OSM_REPO_URL%.git}/tree/$COMMIT"
VERSION=$(sed -n 's/^LAYER_TOOLS_VERSION=//p' "$REPO/versions.env")
USER_AGENT="meshwish-osm-layer/${VERSION:-unknown} (+https://meshwish.ai)"

# 3. Previous build.
rm -rf "$PREV"
PREV_OPTS=$(timeout 1800 "$REPO/scripts/fetch-previous.sh" "$PREV")
CURRENT_PLANET="" CURRENT_ID="" CURRENT_FILE=""
if [[ -f "$PREV/latest.json" ]]; then
  CURRENT_PLANET=$(json_get "$PREV/latest.json" current.planet_date)
  CURRENT_ID=$(json_get "$PREV/latest.json" current.build_id)
fi
# The planet file the current build was made from (YYMMDD, its manifest's input address): what the
# mirror's newest is compared with. planet_date is the file header's replication time, which need
# not be the day the file is named after.
if [[ -f "$PREV/prev-manifest.json" ]]; then
  CURRENT_FILE=$( (json_get "$PREV/prev-manifest.json" inputs.osm.url || true) |
                  grep -o 'planet-[0-9]\{6\}\.osm\.pbf' | sed 's/planet-\([0-9]*\).*/\1/' || true)
fi
say "current build: ${CURRENT_ID:-none} (planet ${CURRENT_PLANET:-none}, file ${CURRENT_FILE:-unknown})"

# 4. Decide. The same listing build.sh reads for --planet latest.
NEWEST=$(curl -fsS -m 60 --retry 3 -A "$USER_AGENT" "$PLANET_MIRROR/" | grep -o 'planet-[0-9]\{6\}\.osm\.pbf\.md5' |
         sed 's/planet-\([0-9]*\).*/\1/' | sort -u | tail -1 || true)
[[ -n "$NEWEST" ]] || fail "could not find the newest planet file at $PLANET_MIRROR/"
PLANET="20${NEWEST:0:2}-${NEWEST:2:2}-${NEWEST:4:2}"
say "newest planet on the mirror: $PLANET"
# The request stays until a forced build is uploaded: a run that fails leaves it for the next.
FORCE_FILE=0
if [[ -f "$OSM_BASE/force-next-run" ]]; then
  FORCE=1 FORCE_FILE=1
fi
if [[ -n "$CURRENT_FILE" ]]; then
  [[ "$NEWEST" > "$CURRENT_FILE" ]] && NEWER=1 || NEWER=0
else  # a current build of no planet file (a test build, an extract): by date
  [[ -z "$CURRENT_PLANET" || "$PLANET" > "$CURRENT_PLANET" ]] && NEWER=1 || NEWER=0
fi
if [[ "$NEWER" == 0 && "$FORCE" == 0 ]]; then
  # a dry run keeps its own status: it leaves the record of the last real run alone
  [[ "$DRY_RUN" == 1 ]] && STATUS=dry-run || STATUS=skipped
  say "skip: the current build already has the planet of $PLANET (--force or $OSM_BASE/force-next-run to rebuild)"
  exit 0
fi
if [[ "$DRY_RUN" == 1 ]]; then
  # shellcheck disable=SC2086  # option list
  "$REPO/scripts/build.sh" --planet "$NEWEST" $PREV_OPTS --work "$WORK" --dry-run
  STATUS=dry-run
  say "dry run: would build the planet of $PLANET with $TAG and upload it with --prune"
  exit 0
fi

# 5. Clean: earlier builds keep their manifest, parts and logs (the archive is in the bucket; a
# failed build's is gone too by now), the newest 12 of them stay; a planet download only stays
# while it is the one to build.
shopt -s nullglob
for dir in "$WORK"/builds/*/; do
  rm -rf "${dir}input" "${dir}tmp" "${dir}.upload" "${dir}"*.pmtiles "${dir}layerstats.tsv.gz"
done
# shellcheck disable=SC2012  # build ids have no odd characters
ls -1dt "$WORK"/builds/*/ 2>/dev/null | tail -n +13 | while read -r old; do rm -rf "$old"; done
rm -rf "$WORK"/.stage-*
for f in "$WORK"/downloads/planet/planet-*.osm.pbf "$WORK"/downloads/planet/planet-*.osm.pbf.part; do
  [[ "$f" == */planet-$NEWEST.osm.pbf* ]] || rm -f "$f"
done
# shellcheck disable=SC2012
ls -1dt "$WORK"/downloads/osmdata/*/ 2>/dev/null | tail -n +3 | while read -r old; do rm -rf "$old"; done
shopt -u nullglob
FREE_GB=$(df -Pk "$WORK" | awk 'NR==2 {printf "%d", $4 / 1048576}')
[[ "$FREE_GB" -ge "$OSM_MIN_FREE_GB" ]] || fail "only $FREE_GB GB free under $WORK, need $OSM_MIN_FREE_GB"

# 6. Build. timeout signals build.sh's whole process group; the docker clients pass it on.
BEFORE=$(ls -1d "$WORK"/builds/*/ 2>/dev/null | sort || true)
BUILT=1
set +e
# shellcheck disable=SC2086  # option list
OUT=$(timeout --kill-after=300 "$OSM_BUILD_TIMEOUT" "$REPO/scripts/build.sh" --planet "$NEWEST" $PREV_OPTS \
      --work "$WORK" --delete-input)
rc=$?
set -e
BUILD_DIR=$(printf '%s\n' "$OUT" | tail -1)
if [[ "$rc" != 0 || ! -f "$BUILD_DIR/manifest.json" ]]; then
  # For its logs: a directory this run made (build.sh moves a failed run's stage to builds/), none
  # when it made none (killed before it could): never an earlier build's.
  BUILD_DIR=$(comm -13 <(printf '%s\n' "$BEFORE") <(ls -1d "$WORK"/builds/*/ 2>/dev/null | sort) | tail -1 || true)
  BUILD_DIR=${BUILD_DIR%/}
  fail "build.sh exited with $rc$([[ "$rc" == 124 ]] && echo " (timed out after $OSM_BUILD_TIMEOUT s)")"
fi
FAILURES=$(json_get "$BUILD_DIR/manifest.json" checks.failures)
[[ "$FAILURES" == "[]" ]] || fail "the build failed its checks: $FAILURES"
say "built ${BUILD_DIR##*/}: $(json_get "$BUILD_DIR/manifest.json" output.bytes) bytes, checks passed"

# 7. Upload, latest.json last, then prune to current and previous.
timeout --kill-after=120 "$OSM_UPLOAD_TIMEOUT" "$REPO/scripts/upload.sh" "$BUILD_DIR" --prune ||
  fail "upload.sh failed: latest.json is replaced only once the archive is checked, but the prune comes after it; see which build the bucket's latest.json names"
rm -f "$BUILD_DIR"/*.pmtiles
rm -rf "$BUILD_DIR/input"
[[ "$FORCE_FILE" == 1 ]] && rm -f "$OSM_BASE/force-next-run"
STATUS=ok
say "uploaded ${BUILD_DIR##*/}; latest.json points at it"
