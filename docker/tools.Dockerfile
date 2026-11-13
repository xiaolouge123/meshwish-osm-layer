# Tools image for scripts/build.sh: osmium-tool filters and inspects OSM files, python3 runs
# scripts/tools/*.py (numpy for the water polygon statistics). The base is pinned by digest in
# versions.env; Debian package versions are recorded in every build manifest.
ARG BASE
FROM ${BASE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends osmium-tool python3 python3-numpy \
 && rm -rf /var/lib/apt/lists/*
