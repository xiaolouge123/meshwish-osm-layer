#!/usr/bin/env bash
# Delete build servers whose delete-after label has passed: the guard for a server that could
# not delete itself (see launch.sh). Run it by hand or from cron with the builder project's token.
#
#   HCLOUD_TOKEN=... hetzner/reap.sh [--dry-run]
set -euo pipefail
DRY=0
[[ "${1:-}" == --dry-run ]] && DRY=1
now=$(date +%s)
hcloud server list -l meshwish-osm-build=1 -o json |
  python3 -I -c 'import json, sys
for s in json.load(sys.stdin) or []:
    print(s["name"], s.get("labels", {}).get("delete-after", "0"))' |
  while read -r name deadline; do
    if [[ "$now" -gt "$deadline" ]]; then
      echo "deleting $name (deadline $deadline passed)"
      [[ "$DRY" == 1 ]] || hcloud server delete "$name"
    else
      echo "keeping $name (deadline in $(( (deadline - now) / 60 )) min)"
    fi
  done
