# syntax=docker/dockerfile:1

# Etapa 1: Extracción de binarios estáticos
FROM caddy:2-alpine AS bin-caddy
FROM rclone/rclone:latest AS bin-rclone
FROM owncloud/ocis:latest AS bin-ocis
FROM litestream/litestream:latest AS bin-litestream
FROM ghcr.io/stonith404/pocket-id:latest AS bin-pocketid

# Etapa 2: Imagen base limpia (Debian Slim evita desajustes de glibc en binarios Go)
FROM debian:bookworm-slim

# Dependencias mínimas del sistema y limpieza en el mismo paso
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    tzdata \
    netcat-traditional \
    procps \
    sqlite3 \
    jq \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Copiar ejecutables
COPY --from=bin-caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=bin-rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=bin-ocis /usr/bin/ocis /usr/local/bin/ocis
COPY --from=bin-litestream /usr/local/bin/litestream /usr/local/bin/litestream
# Pocket-ID suele empaquetar backend y frontend en /app
COPY --from=bin-pocketid /app /opt/pocket-id

# Directorios de trabajo
RUN mkdir -p /data/system /data/cache/rclone /etc/app

COPY Caddyfile /etc/app/Caddyfile
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80 443 9200
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
