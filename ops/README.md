# Monthly build on a long-lived server

A systemd timer that rebuilds the layer from the newest planet once a month and publishes it,
on a server that stays up (the other way is a short-lived Hetzner Cloud server per build:
`hetzner/`, see the main README).

| file | installed as |
|---|---|
| `monthly-build.sh` | `/usr/local/sbin/meshwish-osm-monthly` |
| `meshwish-osm-monthly.service`, `meshwish-osm-monthly.timer` | `/etc/systemd/system/` |
| `meshwish-osm.slice` | `/etc/systemd/system/` (the build containers' slice) |
| `monthly-build.env.example` | `/etc/meshwish-osm/monthly-build.env` (root, 0600, with the storage key) |

## What a run does

The timer starts the service on the first Thursday of each month at 01:30 UTC (plus up to
30 min; a run missed while the server was down starts at boot). `monthly-build.sh` then:

1. takes a lock (`flock` on `$OSM_BASE/monthly.lock`); a second run while one is going fails;
2. fetches this repository into `$OSM_BASE/repo` and checks out the newest `vX.Y.Z` tag on
   `main` (or the tag pinned with `OSM_REPO_REF`). The wrapper is installed separately, so a
   new tag changes the build scripts, not the wrapper;
3. runs `scripts/fetch-previous.sh` (latest.json, the current manifest, the last accepted water
   polygons);
4. compares the newest planet on the mirror with the current build's `planet_date`: the same
   planet is a **skip** (exit 0). `--force`, or the file `$OSM_BASE/force-next-run`, builds
   anyway (e.g. after a rule change);
5. cleans up: earlier builds keep only their manifest, parts and logs (the newest 12), old planet
   downloads and all but the newest two water polygon downloads go; then it needs
   `OSM_MIN_FREE_GB` (160) free;
6. runs `scripts/build.sh --planet <date> --delete-input` (5 h at most). A build whose checks
   fail is never uploaded;
7. runs `scripts/upload.sh --prune` (2 h at most): archive and manifest first and checked,
   latest.json last; then only the current and the previous build stay in the bucket. A failed
   upload leaves latest.json on the previous build;
8. whatever happened: stops any container of the run that is still going, uploads the build's
   logs to `logs/<time>-<ok|failed>/` in the bucket, writes `$OSM_BASE/last-run.json` and
   `$OSM_BASE/logs/monthly-<time>.log` (the newest 24 stay; the journal has them too), and
   posts to `NOTIFY_WEBHOOK_URL` if set (on failure by default).

Exit status 0 means built and uploaded, skipped or dry run; 1 means failed, and the unit shows
as failed (`systemctl --failed`).

## Resources

A planet build took 61 min on 16 threads / 61 GiB with the defaults: all cores, 18 GB of RAM in
use plus page cache for the 50 GB node map, 120 GB of work files at the peak and 27 GB left
after. The containers run in `meshwish-osm.slice` with CPU and IO weight 20 (others have 100), so
other work on the server comes first when they compete; the wrapper's own downloads and
checksums run at `Nice=10` and IO weight 20. On a server with other work, also:

- set `MemoryHigh` / `MemoryMax` in the slice (commented there) and lower `PT_MEMORY`, `PT_XMX`,
  `TOOLS_MEMORY` and `PT_CPUS` / `TOOLS_CPUS` in the env file to match: the build gets slower
  (less page cache for the node map), not wrong;
- check the timer's hour against that work's quiet hours (`OnCalendar` in the timer);
- or build on a short-lived cloud server instead (`hetzner/launch.sh`, about €0.6 a build).

## Install

Needs Ubuntu 24.04 or similar (systemd 250+), docker with the systemd cgroup driver, git, curl,
python3, and 160 GB free under `/srv`. Run as root (or with sudo), from a checkout of this
repository at the tag to install:

```sh
# 1. a user for the build; the docker group is given by the unit only, not permanently
useradd --system --user-group --home-dir /srv/osm-layer/monthly --shell /usr/sbin/nologin osm-build
install -d -o osm-build -g osm-build -m 750 /srv/osm-layer/monthly
docker info -f '{{.CgroupDriver}}'      # systemd; otherwise set OSM_DOCKER_SLICE= (empty)

# 2. the wrapper and the units
install -m 755 ops/monthly-build.sh /usr/local/sbin/meshwish-osm-monthly
install -m 644 ops/meshwish-osm-monthly.service ops/meshwish-osm-monthly.timer ops/meshwish-osm.slice \
  /etc/systemd/system/

# 3. the settings: fill in the storage key (and a webhook if wanted)
install -d -m 700 /etc/meshwish-osm
install -m 600 ops/monthly-build.env.example /etc/meshwish-osm/monthly-build.env
editor /etc/meshwish-osm/monthly-build.env
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/meshwish-osm-monthly.service \
  /etc/systemd/system/meshwish-osm-monthly.timer /etc/systemd/system/meshwish-osm.slice

# 4. a dry run: checkout, previous build, newest planet, the decision, build.sh --dry-run
#    (rule tests and the planet's md5 only; nothing is built, uploaded or deleted)
systemd-run --wait --pipe --collect -p User=osm-build -p Group=osm-build \
  -p SupplementaryGroups=docker -p EnvironmentFile=/etc/meshwish-osm/monthly-build.env \
  /usr/local/sbin/meshwish-osm-monthly --dry-run

# 5. switch the timer on
systemctl enable --now meshwish-osm-monthly.timer
systemctl list-timers meshwish-osm-monthly.timer
```

`OSM_BASE` other than `/srv/osm-layer/monthly` must be changed in the service's
`ReadWritePaths` and the user's home as well.

## Running it by hand and watching it

```sh
systemctl start --no-block meshwish-osm-monthly.service   # a real run now (skips an unchanged planet)
sudo -u osm-build touch /srv/osm-layer/monthly/force-next-run   # make the next run build anyway
journalctl -u meshwish-osm-monthly.service -f              # follow it
systemctl status meshwish-osm-monthly.service              # last result
cat /srv/osm-layer/monthly/last-run.json                   # status, tag, planet, build id, log file
ls -t /srv/osm-layer/monthly/logs/                         # one log per run
systemctl stop meshwish-osm-monthly.service                # stop a run: containers are stopped too
```

A run that is stopped or fails leaves latest.json where it was: readers keep the current build.

## Updating, pausing, removing

- New build code needs nothing: the next run takes the newest tag (unless `OSM_REPO_REF` pins
  one). A new wrapper or new units: install them again as in step 2, then `systemctl daemon-reload`.
- Pause: `systemctl disable --now meshwish-osm-monthly.timer`.
- Remove:

```sh
systemctl disable --now meshwish-osm-monthly.timer
rm /etc/systemd/system/meshwish-osm-monthly.service /etc/systemd/system/meshwish-osm-monthly.timer \
  /etc/systemd/system/meshwish-osm.slice /usr/local/sbin/meshwish-osm-monthly
systemctl daemon-reload
# and, if nothing else uses them: /etc/meshwish-osm, /srv/osm-layer/monthly, the user osm-build
```

## Security

- The storage key in the env file can write and delete in the bucket (upload and `--prune` need
  that): scope it to this bucket alone. systemd reads the file as root; the build user cannot.
- The docker group is root-equivalent on the server. The unit is hardened (read-only system,
  no new privileges, no capabilities), but what limits the build is what its containers get:
  they run as `osm-build`, with memory and CPU limits, in their own slice.
- With `OSM_REPO_REF` empty the server runs whatever the newest tag on `main` of this
  repository holds: anyone who can push a tag there can run code on it as `osm-build`. Pin a
  reviewed tag to rule that out, and move the pin by hand.
