#!/usr/bin/env bash
set -Eeuo pipefail

# Estructura del volumen unificado
mkdir -p /data/cache/rclone \
         /data/system/caddy \
         /data/system/pocket-id \
         /data/system/ocis/config

# Función para prefijar logs a stdout sin acumular archivos de texto residuales
log_pipe() {
    local prefix="$1"
    while IFS= read -r line; do
        printf "[%s] %s\n" "${prefix}" "${line}"
    done
}

# Trampa de señales: si Docker manda SIGTERM, apagamos todos los hijos ordenadamente
cleanup() {
    echo "[SYSTEM] Deteniendo servicios..."
    kill -TERM $(jobs -p) 2>/dev/null || true
    wait
    echo "[SYSTEM] Contenedor detenido de forma limpia."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------
# 1. Recuperación SQLite (Litestream)
# ---------------------------------------------------------
echo "[SYSTEM] Verificando backups previos en S3..."
if [ -n "${S3_BUCKET_BACKUP:-}" ]; then
    litestream restore -if-replica-exists -config /etc/app/litestream.yml /data/system/pocket-id/pocket-id.db 2>&1 | log_pipe "litestream-init" || true
fi

# ---------------------------------------------------------
# 2. Rclone: Pasarela S3 local + Cifrado Crypt + Purgado VFS
# ---------------------------------------------------------
echo "[SYSTEM] Iniciando rclone serve s3..."
rclone serve s3 "${RCLONE_REMOTE}:" \
    --addr "127.0.0.1:8080" \
    --cache-dir "/data/cache/rclone" \
    --vfs-cache-mode full \
    --vfs-cache-min-free-space 30% \
    --vfs-cache-max-age 48h \
    --no-modtime \
    2>&1 | log_pipe "rclone" &

# Esperar a que rclone responda
while ! nc -z 127.0.0.1 8080; do sleep 0.5; done

# ---------------------------------------------------------
# 3. Pocket-ID (Proveedor OIDC) + Replicación continua
# ---------------------------------------------------------
echo "[SYSTEM] Iniciando Litestream y Pocket-ID..."
litestream replicate -config /etc/app/litestream.yml 2>&1 | log_pipe "litestream" &

(cd /opt/pocket-id && ./pocket-id) 2>&1 | log_pipe "pocket-id" &

while ! nc -z 127.0.0.1 8081; do sleep 0.5; done

# ---------------------------------------------------------
# 4. OCIS (ownCloud Infinite Scale)
# ---------------------------------------------------------
echo "[SYSTEM] Verificando e iniciando OCIS..."
export OCIS_BASE_DATA_PATH="/data/system/ocis"
export STORAGE_USERS_DRIVER="s3"
export STORAGE_USERS_S3_ENDPOINT="http://127.0.0.1:8080"
export STORAGE_USERS_S3_REGION="default"
export STORAGE_USERS_S3_BUCKET="${OCIS_S3_BUCKET:-ocis}"

if [ ! -f "/data/system/ocis/config/ocis.yaml" ]; then
    echo "[SYSTEM] Inicializando configuración base de OCIS..."
    ocis init --insecure true 2>&1 | log_pipe "ocis-init"
fi

ocis server 2>&1 | log_pipe "ocis" &

while ! nc -z 127.0.0.1 9200; do sleep 1; done

# ---------------------------------------------------------
# 5. Caddy (Puerta de enlace)
# ---------------------------------------------------------
echo "[SYSTEM] Levantando Caddy Proxy..."
caddy run --config /etc/app/Caddyfile 2>&1 | log_pipe "caddy" &

echo "[SYSTEM] Todo el stack está operativo."

# Failsafe: Si CUALQUIER proceso hijo muere, el script falla y Docker reinicia el contenedor
wait -n
