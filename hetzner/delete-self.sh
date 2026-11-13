#!/bin/bash
# Delete this Hetzner server through the API; installed as /usr/local/sbin/meshwish-osm-delete-self
# by launch.sh. bootstrap.sh calls it when the build ends, the boot-time watchdog timer after
# MAX_HOURS. Deleting (not powering off) is what stops the billing.
# shellcheck source=/dev/null
. /etc/meshwish-osm/env
id=$(curl -fsS --max-time 10 http://169.254.169.254/hetzner/v1/metadata/instance-id)
echo "$(date -u +%FT%TZ) deleting server $id ($1)" >>/var/log/meshwish-osm.log
for _ in 1 2 3 4 5 6; do
  curl -fsS --max-time 30 -X DELETE -H "Authorization: Bearer $HCLOUD_TOKEN" \
    "https://api.hetzner.cloud/v1/servers/$id" >/dev/null && exit 0
  sleep 60
done
echo "$(date -u +%FT%TZ) could not delete the server; hetzner/reap.sh has to" >>/var/log/meshwish-osm.log
poweroff
