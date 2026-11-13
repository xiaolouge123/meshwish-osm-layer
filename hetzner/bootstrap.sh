#!/bin/bash
# First thing the build server runs (cloud-init starts it as a systemd unit; installed as
# /usr/local/sbin/meshwish-osm-bootstrap by launch.sh): install docker, clone this repository at
# REPO_REF, run hetzner/run.sh from that checkout, then delete the server whatever happened.
set -uo pipefail
exec >>/var/log/meshwish-osm.log 2>&1
trap '/usr/local/sbin/meshwish-osm-delete-self finished' EXIT
# shellcheck source=/dev/null
. /etc/meshwish-osm/env
echo "$(date -u +%FT%TZ) bootstrap $NAME"
export DEBIAN_FRONTEND=noninteractive
# a fresh Ubuntu runs its own apt jobs at boot: wait for their lock instead of failing
apt_get() { apt-get -o DPkg::Lock::Timeout=900 "$@"; }
apt_get update -q && apt_get install -y -q docker.io docker-buildx git curl || exit 1
git clone -q "$REPO_URL" /opt/meshwish-osm-layer && git -C /opt/meshwish-osm-layer checkout -q "$REPO_REF" || exit 1
bash /opt/meshwish-osm-layer/hetzner/run.sh
