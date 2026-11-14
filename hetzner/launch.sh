#!/usr/bin/env bash
# Rent a Hetzner Cloud server for one build: it runs fetch-previous.sh, build.sh and upload.sh
# from this repository, uploads its logs, and deletes itself.
#
#   hetzner/launch.sh [--wait] [--dry-run]
#
# Environment:
#   HCLOUD_TOKEN      read & write API token of a Hetzner project used only for these builds. The
#                     server gets it too, to delete itself, so keep nothing else in that project.
#   REPO_URL          public https URL of this repository; REPO_REF the tag or commit to build
#                     (default main). The metadata links to REPO_URL at the commit actually built.
#   OSM_S3_URI, OSM_S3_ENDPOINT, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY   as for scripts/upload.sh
#   BUILD_ARGS        build.sh arguments (default "--planet latest"; European test run "--region europe")
#   UPLOAD_ARGS       upload.sh arguments (default "--prune"; test runs "--no-latest")
#   SERVER_TYPE (ccx43), LOCATION (fsn1), IMAGE (ubuntu-24.04), MAX_HOURS (6)
#   SSH_KEY           name of an SSH key in the project (recommended: lets you log in to debug, and
#                     without one Hetzner generates a root password for the server)
#
# Nothing is left running by mistake; three independent guards delete the server:
#   1. the build script deletes it when it ends, whether it succeeded or not;
#   2. a systemd timer started at boot deletes it after MAX_HOURS even if the build hangs;
#   3. it carries the labels meshwish-osm-build=1 and delete-after=<unix time>: --wait polls and
#      deletes it at that time, and hetzner/reap.sh (run it from cron or by hand) deletes any
#      labelled server past its time.
#
# Cost (Hetzner list prices of 2026-11-10 after the June increase, from cloudtally.eu; check
# the console before relying on them): CCX43, 16 dedicated vCPU / 64 GB / 360 GB NVMe, about
# EUR 0.44 per hour plus EUR 0.001 per hour for the IPv4 address; traffic in is free. A planet
# build takes about 1-1.5 h (download ~96 GB, filter, tile, upload ~22 GB): EUR 0.5-0.7. The
# European test run (~33 GB extract) about 30 min: EUR 0.25. The MAX_HOURS guard caps a stuck
# run at 6 h, EUR 2.7. Storage on R2 is separate: about USD 0.4 a month per planet build kept.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)

WAIT=0 DRY=0
for a in "$@"; do
  case $a in
    --wait) WAIT=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument $a" >&2; exit 2 ;;
  esac
done
for v in HCLOUD_TOKEN REPO_URL OSM_S3_URI OSM_S3_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  [[ -n "${!v:-}" ]] || { echo "$v is not set" >&2; exit 1; }
done
[[ "$DRY" == 1 ]] || command -v hcloud >/dev/null || { echo "install the hcloud CLI first" >&2; exit 1; }
REPO_REF=${REPO_REF:-main}
BUILD_ARGS=${BUILD_ARGS:---planet latest}
UPLOAD_ARGS=${UPLOAD_ARGS:---prune}
SERVER_TYPE=${SERVER_TYPE:-ccx43}
LOCATION=${LOCATION:-fsn1}
IMAGE=${IMAGE:-ubuntu-24.04}
MAX_HOURS=${MAX_HOURS:-6}
[[ "$MAX_HOURS" =~ ^[0-9]+$ && "$MAX_HOURS" -ge 1 && "$MAX_HOURS" -le 24 ]] || { echo "MAX_HOURS must be 1-24" >&2; exit 1; }
NAME=meshwish-osm-$(date -u +%Y%m%d-%H%M)
DEADLINE=$(( $(date +%s) + MAX_HOURS * 3600 ))

b64() { base64 | tr -d '\n'; }
env_file() {
  local v
  for v in HCLOUD_TOKEN REPO_URL REPO_REF OSM_S3_URI OSM_S3_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
           BUILD_ARGS UPLOAD_ARGS NAME; do
    printf '%s=%q\n' "$v" "${!v}"
  done
  printf 'export %s\n' "OSM_S3_URI OSM_S3_ENDPOINT AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY"
}

USER_DATA=$(mktemp)
chmod 600 "$USER_DATA"
trap 'rm -f "$USER_DATA"' EXIT
cat >"$USER_DATA" <<EOF
#cloud-config
bootcmd:
  - [systemd-run, --unit=meshwish-osm-watchdog, --on-active=${MAX_HOURS}h, /usr/local/sbin/meshwish-osm-delete-self, watchdog]
write_files:
  - path: /etc/meshwish-osm/env
    permissions: '0600'
    encoding: b64
    content: $(env_file | b64)
  - path: /usr/local/sbin/meshwish-osm-delete-self
    permissions: '0700'
    encoding: b64
    content: $(b64 <"$HERE/delete-self.sh")
  - path: /usr/local/sbin/meshwish-osm-bootstrap
    permissions: '0700'
    encoding: b64
    content: $(b64 <"$HERE/bootstrap.sh")
runcmd:
  - [systemd-run, --unit=meshwish-osm-build, /usr/local/sbin/meshwish-osm-bootstrap]
EOF

args=(server create --name "$NAME" --type "$SERVER_TYPE" --image "$IMAGE" --location "$LOCATION"
      --user-data-from-file "$USER_DATA" --label meshwish-osm-build=1 --label "delete-after=$DEADLINE")
[[ -n "${SSH_KEY:-}" ]] && args+=(--ssh-key "$SSH_KEY")
if [[ "$DRY" == 1 ]]; then
  echo "hcloud ${args[*]}"
  sed 's/^\(    content: \).*/\1<base64 omitted>/' "$USER_DATA"
  exit 0
fi
hcloud "${args[@]}"
echo "server $NAME started; deadline $(date -u -r "$DEADLINE" 2>/dev/null || date -u -d "@$DEADLINE")"
echo "logs go to $OSM_S3_URI/logs/; ssh root@<ip> then: tail -f /var/log/meshwish-osm.log"

if [[ "$WAIT" == 1 ]]; then
  while hcloud server describe "$NAME" >/dev/null 2>&1; do
    if [[ $(date +%s) -gt $(( DEADLINE + 600 )) ]]; then
      echo "deadline passed; deleting $NAME"
      hcloud server delete "$NAME"
      exit 1
    fi
    sleep 300
  done
  echo "server $NAME is gone (build finished)"
fi
