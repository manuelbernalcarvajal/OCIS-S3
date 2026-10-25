#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 0. CANALIZACIÓN DE LOGS Y SEÑALES POSIX
# ==============================================================================
log() {
    local service="$1"
    shift
    printf "[%-12s] %s\n" "${service}" "$*"
}

log_pipe() {
    local service="$1"
    while IFS= read -r line; do
        printf "[%-12s] %s\n" "${service}" "${line}"
    done
}

cleanup() {
    log "SYSTEM" "Señal de parada recibida. Apagando demonios ordenadamente..."
    kill -TERM $(jobs -p) 2>/dev/null || true
    wait
    log "SYSTEM" "Contenedor detenido sin corrupción de datos."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ==============================================================================
# 1. PREPARACIÓN DEL VOLUMEN ÚNICO (/data)
# ==============================================================================
log "STORAGE" "Verificando estructura interna en /data..."
mkdir -p /data/cache/rclone \
         /data/system/caddy \
         /data/system/pocket-id \
         /data/system/ocis/config \
         /tmp/rclone

# ==============================================================================
# 2. AUTO-CONFIGURACIÓN DE RCLONE (S3 Remoto + Cifrado Crypt al vuelo)
# ==============================================================================
log "RCLONE" "Generando configuración en memoria para backend de almacenamiento..."
RCLONE_CONF="/tmp/rclone/rclone.conf"

cat <<EOF > "${RCLONE_CONF}"
[s3-raw]
type = s3
provider = ${S3_PROVIDER:-Other}
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION:-us-east-1}

[crypt-store]
type = crypt
remote = s3-raw:${OCIS_S3_BUCKET}
password = $(rclone obscure "${CRYPT_PASSWORD}")
password2 = $(rclone obscure "${CRYPT_SALT:-${CRYPT_PASSWORD}}")
directory_name_encryption = true
filename_encryption = standard
EOF

log "RCLONE" "Iniciando pasarela S3 interna (127.0.0.1:8080) con purgado inteligente..."
rclone serve s3 crypt-store: \
    --config "${RCLONE_CONF}" \
    --addr "127.0.0.1:8080" \
    --s3-auth-builtin \
    --cache-dir "/data/cache/rclone" \
    --vfs-cache-mode full \
    --vfs-cache-min-free-space 30% \
    --vfs-cache-max-age 48h \
    --no-modtime \
    2>&1 | log_pipe "rclone" &

# Esperar a que el puerto de rclone esté levantado
while ! nc -z 127.0.0.1 8080; do sleep 0.3; done
log "RCLONE" "Servicio S3 local operativo."

# ==============================================================================
# 3. RECUPERACIÓN Y ARRANQUE DE POCKET-ID + LITESTREAM
# ==============================================================================
DB_PATH="/data/system/pocket-id/pocket-id.db"

if [ -n "${S3_BUCKET_BACKUP:-}" ]; then
    log "LITESTREAM" "Consultando réplicas de seguridad en el bucket..."
    litestream restore -if-replica-exists -config /etc/app/litestream.yml "${DB_PATH}" 2>&1 | log_pipe "litestream-sync" || true
fi

log "LITESTREAM" "Iniciando replicación continua de SQLite..."
litestream replicate -config /etc/app/litestream.yml 2>&1 | log_pipe "litestream" &

log "POCKET-ID" "Arrancando proveedor OIDC..."
export DB_PATH="${DB_PATH}"
export APP_URL="https://${DOMAIN_NAME}/id"
export PORT="8081"

(cd /opt/pocket-id && ./pocket-id) 2>&1 | log_pipe "pocket-id" &

while ! nc -z 127.0.0.1 8081; do sleep 0.3; done
log "POCKET-ID" "Proveedor OIDC listo para validar credenciales."

# ==============================================================================
# 4. INICIALIZACIÓN Y ARRANQUE DE OCIS
# ==============================================================================
log "OCIS" "Configurando variables de almacenamiento y conexión OIDC..."

export OCIS_BASE_DATA_PATH="/data/system/ocis"
export OCIS_URL="https://${DOMAIN_NAME}"
export OCIS_INSECURE="true"

# Apuntar el driver S3 de OCIS a nuestra pasarela rclone
export STORAGE_USERS_DRIVER="s3"
export STORAGE_USERS_S3_ENDPOINT="http://127.0.0.1:8080"
export STORAGE_USERS_S3_REGION="default"
export STORAGE_USERS_S3_BUCKET="ocis"
export STORAGE_USERS_S3_ACCESS_KEY="dummy"
export STORAGE_USERS_S3_SECRET_KEY="dummy"

# Vinculación de OCIS con Pocket-ID
export OCIS_OIDC_ISSUER="https://${DOMAIN_NAME}/id"
export WEB_OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-ocis-client}"
export PROXY_OIDC_ISSUER="https://${DOMAIN_NAME}/id"

if [ ! -f "/data/system/ocis/config/ocis.yaml" ]; then
    log "OCIS" "Instalación limpia detectada. Ejecutando 'ocis init'..."
    ocis init --insecure true 2>&1 | log_pipe "ocis-init"
fi

log "OCIS" "Arrancando el núcleo..."
ocis server 2>&1 | log_pipe "ocis" &

while ! nc -z 127.0.0.1 9200; do sleep 0.5; done
log "OCIS" "Monolito de archivos operativo."

# ==============================================================================
# 5. PUERTA DE ACCESO CADDY (Único puerto público)
# ==============================================================================
log "CADDY" "Publicando servicios a través del proxy inverso..."
caddy run --config /etc/app/Caddyfile 2>&1 | log_pipe "caddy" &

log "SYSTEM" "Stack blindado y completamente funcional."

# Si algún microservicio muere de forma inesperada, el contenedor cae para reiniciarse
wait -n
