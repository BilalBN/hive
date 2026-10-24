# The Hive server in a container: Python, FFmpeg, Chromaprint's fpcalc and
# Hive Admin inside. See docs/self-hosting.md (Docker) for running it next
# to Tailscale with deploy/docker/compose.yml.
#
#   docker build -t hive .

FROM node:24-slim AS admin
WORKDIR /src
COPY api/ api/
COPY admin/package.json admin/package-lock.json admin/
RUN npm ci --prefix admin
COPY admin/ admin/
RUN npm run build --prefix admin

FROM python:3.12-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg libchromaprint-tools \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/hive
COPY api/openapi.yaml api/openapi.yaml
COPY server/ server/
RUN pip install --no-cache-dir ./server && rm -rf server
COPY --from=admin /src/admin/dist /opt/hive/admin

# Data in /data, music in /music. Listening on every address inside the
# container is meant for running next to Tailscale (network_mode:
# service:tailscale), where the only way in is the private network; don't
# publish the port to your home network or the internet.
ENV HIVE_DATA_DIR=/data \
    HIVE_HOST=0.0.0.0 \
    HIVE_MUSIC_FOLDERS='["/music"]' \
    HIVE_ADMIN_DIST=/opt/hive/admin
VOLUME ["/data"]
EXPOSE 8443
HEALTHCHECK --interval=60s --timeout=5s \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8443/api/v1/health')"
CMD ["hive", "serve"]
