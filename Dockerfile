# Python 3.12: rookiepy provides cp312 manylinux wheels; 3.13+ may not build.
# rookiepy is included so legacy `docker run image --cookies-from-chrome` style
# usage keeps working when the host has Chrome's cookie DB mounted, but the
# scheduled / unattended path uses only the refresh-token strategy.
FROM python:3.12-slim-bookworm

WORKDIR /app
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOMERUN_OUTPUT_DIR=/output \
    HOMERUN_STATE_DIR=/state

# tini gives us PID 1 signal handling for clean docker stop.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Application code. The auth/ package and entrypoint script make this image
# self-contained for unattended use.
COPY pull_info_from_opp.py ./
COPY auth/ ./auth/
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Volumes:
#   /state  — persisted cookies.txt (must be writable; mode 0600)
#   /output — Markdown export destination (Drive-synced on the host)
VOLUME ["/state", "/output"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
# Default to the legacy exporter help so old `docker run image --help` works.
CMD ["--help"]
