# Shared helpers for build.sh, upload.sh and fetch-previous.sh (sourced, not run).
#
# Host requirements: bash (3.2 or later), curl, docker, coreutils (sha256sum or shasum).
# Everything that reads downloaded data runs in containers: osmium and Python in the tools image built from
# docker/tools.Dockerfile, planetiler and the AWS CLI from images pinned in versions.env.

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=versions.env
. "$REPO_DIR/versions.env"

# The only identification we send anywhere: tool name, version and the project URL.
USER_AGENT="meshwish-osm-layer/${LAYER_TOOLS_VERSION} (+https://meshwish.ai)"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
md5_of() {
  if command -v md5sum >/dev/null; then md5sum "$1" | cut -d' ' -f1; else md5 -q "$1"; fi
}
file_size() { wc -c <"$1" | tr -d ' '; }

# Total memory in GiB, for resource defaults.
host_mem_gib() {
  if [[ -r /proc/meminfo ]]; then
    awk '/MemTotal/ {printf "%d", $2 / 1048576}' /proc/meminfo
  else
    echo $(( $(sysctl -n hw.memsize) / 1073741824 ))
  fi
}
host_cpus() { getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu; }
# Containers run as the calling user, so files they write stay removable without root.
DOCKER_USER=(--user "$(id -u):$(id -g)" -e HOME=/tmp)
# DOCKER_RUN_ARGS adds options to every container, split on whitespace. The monthly job (ops/)
# puts the containers in its low-priority slice and labels them with the run, so it can stop
# them: "--cgroup-parent=meshwish-osm.slice --label=meshwish-osm-run=<time>".
if [[ -n "${DOCKER_RUN_ARGS:-}" ]]; then
  read -r -a _docker_run_args <<<"$DOCKER_RUN_ARGS"
  # guarded: an empty array is "unbound" under set -u in bash 3.2 (macOS)
  DOCKER_USER+=(${_docker_run_args[@]+"${_docker_run_args[@]}"})
fi

# fetch URL DEST: resumable download with our User-Agent, retried on any error (a 404 too, so
# probe uncertain URLs another way); DEST only appears when complete.
fetch() {
  local url=$1 dest=$2
  mkdir -p "$(dirname "$dest")"
  log "download $url"
  curl --fail --location --silent --show-error --retry 5 --retry-all-errors --retry-delay 30 --connect-timeout 30 \
    --continue-at - -A "$USER_AGENT" -o "$dest.part" "$url" || return 1
  mv "$dest.part" "$dest"
}

# Tools image: tagged by a hash of its Dockerfile and base, rebuilt when either changes.
tools_image() {
  local tag
  tag=$( (cat "$REPO_DIR/docker/tools.Dockerfile"; echo "$TOOLS_BASE_IMAGE") | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)
  TOOLS_IMAGE="meshwish-osm-tools:$tag"
  if ! docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
    log "building $TOOLS_IMAGE"
    docker build -q -f "$REPO_DIR/docker/tools.Dockerfile" --build-arg "BASE=$TOOLS_BASE_IMAGE" \
      -t "$TOOLS_IMAGE" "$REPO_DIR/docker" >/dev/null
  fi
}

# tools CMD...: run in the tools image with $WORK_DIR at /work (read-write) and the Python
# tools at /tools (read-only); paths given to it must be under /work.
tools() {
  docker run --rm "${DOCKER_USER[@]}" --memory "${TOOLS_MEMORY:-4g}" --cpus "${TOOLS_CPUS:-4}" \
    -v "$WORK_DIR:/work" -v "$REPO_DIR/scripts/tools:/tools:ro" -v "$REPO_DIR/schema:/schema:ro" \
    -w /work "$TOOLS_IMAGE" timeout "${TOOLS_TIMEOUT:-21600}" "$@"
}
py() { tools python3 -I "/tools/$1" "${@:2}"; }

# AWS CLI in docker for S3-compatible storage (Cloudflare R2). Env: OSM_S3_ENDPOINT,
# AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION (auto for R2). Mounts $1 at /work.
aws_cli() {
  local dir=$1
  shift
  local endpoint=()
  [[ -n "${OSM_S3_ENDPOINT:-}" ]] && endpoint=(--endpoint-url "$OSM_S3_ENDPOINT")
  docker run --rm "${DOCKER_USER[@]}" --memory "${AWS_MEMORY:-2g}" \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-auto}" \
    -e AWS_CONFIG_FILE=/work/.aws-config \
    -e AWS_REQUEST_CHECKSUM_CALCULATION=when_required -e AWS_RESPONSE_CHECKSUM_VALIDATION=when_required \
    ${AWS_DOCKER_NETWORK:+--network "$AWS_DOCKER_NETWORK"} \
    -v "$dir:/work" -w /work "$AWSCLI_IMAGE" ${endpoint[@]+"${endpoint[@]}"} --no-cli-pager "$@"
}

# Write the multipart settings aws_cli reads from <dir>/.aws-config.
aws_config() {
  cat >"$1/.aws-config" <<EOF
[default]
s3 =
  multipart_threshold = 64MB
  multipart_chunksize = ${S3_CHUNK_MB:-256}MB
  max_concurrent_requests = ${S3_CONCURRENCY:-8}
EOF
}

# split_s3_uri s3://bucket/prefix -> sets S3_BUCKET and S3_PREFIX (no trailing slash).
split_s3_uri() {
  local uri=${1#s3://}
  [[ "$1" == s3://* && -n "$uri" ]] || die "expected s3://bucket/prefix, got '$1'"
  S3_BUCKET=${uri%%/*}
  S3_PREFIX=${uri#"$S3_BUCKET"}
  S3_PREFIX=${S3_PREFIX#/}
  S3_PREFIX=${S3_PREFIX%/}
}

# s3_get_optional DIR S3URL DEST: download a small object; returns 1 when it does not exist and
# dies on any other error, so a failing read is never mistaken for "no previous build".
s3_get_optional() {
  local dir=$1 url=$2 dest=$3 err
  err=$(aws_cli "$dir" s3 cp "$url" "$dest" --only-show-errors 2>&1) && return 0
  if [[ "$err" == *"404"* || "$err" == *"Not Found"* || "$err" == *"NoSuchKey"* ]]; then
    return 1
  fi
  die "cannot read $url: $err"
}
