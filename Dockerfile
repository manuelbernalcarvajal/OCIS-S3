# syntax=docker/dockerfile:1

# Etapa 1: Extracción de binarios estáticos
FROM caddy:2-alpine AS bin-caddy
FROM rclone/rclone:latest AS bin-rclone
FROM litestream/litestream:latest AS bin-litestream
FROM ghcr.io/pocket-id/pocket-id:latest AS bin-pocketid

# Etapa 2: Imagen base nativa de OCIS (incluye musl, libvips y el binario en /usr/bin/ocis)
FROM owncloud/ocis:latest

USER root

# Dependencias mínimas para los scripts
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    tzdata \
    netcat-openbsd \
    procps \
    sqlite \
    jq

# Copiar ejecutables adicionales
COPY --from=bin-caddy /usr/bin/caddy /usr/local/bin/caddy
COPY --from=bin-rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=bin-litestream /usr/local/bin/litestream /usr/local/bin/litestream
COPY --from=bin-pocketid /app /opt/pocket-id

# Directorios de trabajo
RUN mkdir -p /data/system /data/cache/rclone /etc/app

# Copiar archivos de configuración y scripts
COPY Caddyfile /etc/app/Caddyfile
COPY litestream.yml /etc/app/litestream.yml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY gc.sh /usr/local/bin/gc.sh

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/gc.sh

EXPOSE 80 443 443/udp
VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
