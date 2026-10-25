#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 0. LOGGING, CONTROL DE SEÑALES Y VALIDACIÓN
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

PIDS=()
cleanup() {
    log "SYSTEM" "Señal de parada recibida. Cerrando servicios ordenadamente..."
    if [ "${#PIDS[@]}" -gt 0 ]; then
        kill -TERM "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi
    log "SYSTEM" "Contenedor apagado limpiamente."
    exit 0
}
trap cleanup SIGTERM SIGINT

REQUIRED_VARS=(
    "DOMAIN_NAME"
    "S3_ENDPOINT"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
    "OCIS_S3_BUCKET"
    "CRYPT_PASSWORD"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        log "ERROR" "Falta la variable de entorno obligatoria: ${var}"
        exit 1
    fi
done

# ==============================================================================
# 1. PARCHE DE RED Y DIRECTORIOS
# ==============================================================================
# Mapear tanto el dominio principal como el subdominio de Pocket ID al bucle local
if [ "${BEHIND_PROXY:-false}" != "true" ]; then
    for host in "${DOMAIN_NAME}" "id.${DOMAIN_NAME}"; do
        if ! grep -q "${host}" /etc/hosts 2>/dev/null; then
            echo "127.0.0.1 ${host}" >> /etc/hosts 2>/dev/null || true
            log "SYSTEM" "Bypass DNS local aplicado para ${host}."
        fi
    done
fi

mkdir -p /data/cache/rclone \
         /data/system/caddy \
         /data/system/pocket-id \
         /data/system/ocis/config \
         /etc/app

rm -rf /opt/pocket-id/data
ln -s /data/system/pocket-id /opt/pocket-id/data

# ==============================================================================
# 2. GENERACIÓN DINÁMICA DE CADDYFILE (VIRTUAL HOSTS)
# ==============================================================================
CADDY_CONFIG="/etc/app/Caddyfile"

if [ "${BEHIND_PROXY:-false}" = "true" ]; then
    log "CADDY" "Modo proxy exterior activo (HTTP plano :80)."
    cat <<EOF > "${CADDY_CONFIG}"
{
    admin off
    auto_https off
}

:80 {
    @id host id.${DOMAIN_NAME}
    handle @id {
        reverse_proxy 127.0.0.1:8081
    }

    handle {
        reverse_proxy https://127.0.0.1:9200 {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
}
EOF
else
    log "CADDY" "Modo directo activo (ACME + TLS 1.3 / QUIC)."
    cat <<EOF > "${CADDY_CONFIG}"
{
    admin off
    storage file_system {
        root /data/system/caddy
    }
    ${ACME_EMAIL:+email ${ACME_EMAIL}}
}

id.${DOMAIN_NAME} {
    reverse_proxy 127.0.0.1:8081
}

${DOMAIN_NAME} {
    reverse_proxy https://127.0.0.1:9200 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
fi

# ==============================================================================
# 3. PASARELA RCLONE S3
# ==============================================================================
RCLONE_CONFIG="/etc/app/rclone.conf"
log "RCLONE" "Escribiendo configuración en ${RCLONE_CONFIG}..."

cat <<EOF > "${RCLONE_CONFIG}"
[s3-raw]
type = s3
provider = ${S3_PROVIDER:-Other}
access_key_id = ${AWS_ACCESS_KEY_ID}
secret_access_key = ${AWS_SECRET_ACCESS_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION:-us-east-1}
no_check_bucket = true

[crypt-store]
type = crypt
remote = s3-raw:${OCIS_S3_BUCKET}
password = $(rclone obscure "${CRYPT_PASSWORD}")
password2 = $(rclone obscure "${CRYPT_SALT:-${CRYPT_PASSWORD}}")
directory_name_encryption = true
filename_encryption = standard
EOF
chmod 600 "${RCLONE_CONFIG}"

log "RCLONE" "Asegurando existencia física del bucket virtual 'ocis'..."
rclone touch --config "${RCLONE_CONFIG}" crypt-store:ocis/.keep 2>&1 | log_pipe "rclone-init" || true

log "RCLONE" "Iniciando pasarela S3 en 127.0.0.1:8080..."
rclone serve s3 crypt-store: \
    --config "${RCLONE_CONFIG}" \
    --addr "127.0.0.1:8080" \
    --auth-key "dummy,dummy" \
    --cache-dir "/data/cache/rclone" \
    --vfs-cache-mode full \
    --vfs-cache-min-free-space 5G \
    --vfs-cache-max-age 48h \
    --vfs-fast-fingerprint \
    --no-modtime \
    > >(log_pipe "rclone") 2>&1 &
PIDS+=($!)

while ! nc -z 127.0.0.1 8080; do sleep 0.3; done
log "RCLONE" "Pasarela operativa con credenciales explícitas."

# ==============================================================================
# 4. LITESTREAM + POCKET-ID
# ==============================================================================
DB_PATH="/data/system/pocket-id/pocket-id.db"
KEY_FILE="/data/system/pocket-id/encryption.key"

# Usar variable de entorno fija o recuperar/generar en disco
if [ -n "${POCKET_ID_ENCRYPTION_KEY:-}" ]; then
    export ENCRYPTION_KEY="${POCKET_ID_ENCRYPTION_KEY}"
else
    if [ ! -f "${KEY_FILE}" ]; then
        log "POCKET-ID" "Generando clave de cifrado persistente en disco..."
        tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32 > "${KEY_FILE}"
    fi
    export ENCRYPTION_KEY="$(cat "${KEY_FILE}")"
fi
export ENCRYPTION_KEY="${ENCRYPTION_KEY:-$(cat "${KEY_FILE}")}"

# Solo restaurar desde S3 si el archivo local NO existe
if [ ! -f "${DB_PATH}" ]; then
    log "LITESTREAM" "Comprobando réplica previa de base de datos..."
    litestream restore -if-replica-exists -config /etc/app/litestream.yml "${DB_PATH}" > >(log_pipe "litestream-sync") 2>&1 || true
fi

litestream replicate -config /etc/app/litestream.yml > >(log_pipe "litestream") 2>&1 &
PIDS+=($!)

export DB_CONNECTION_STRING="file:${DB_PATH}?_pragma=journal_mode(wal)&_pragma=busy_timeout(5000)"
export APP_URL="https://id.${DOMAIN_NAME}"
export PORT="8081"
export HOST="127.0.0.1"

(cd /opt/pocket-id && ./pocket-id) > >(log_pipe "pocket-id") 2>&1 &
PIDS+=($!)

while ! nc -z 127.0.0.1 8081; do sleep 0.3; done
log "POCKET-ID" "Servicio OIDC listo en 127.0.0.1:8081."

# ==============================================================================
# 5. ENTRADA PÚBLICA CADDY (ARRANCA ANTES DE OCIS)
# ==============================================================================
log "CADDY" "Levantando reverse proxy..."
caddy run --config "${CADDY_CONFIG}" > >(log_pipe "caddy") 2>&1 &
CADDY_PID=$!
PIDS+=(${CADDY_PID})

# Esperar a que Caddy abra puerto o detectar si muere de inmediato
while ! nc -z 127.0.0.1 80 && ! nc -z 127.0.0.1 443; do
    if ! kill -0 "${CADDY_PID}" 2>/dev/null; then
        log "ERROR" "Caddy se cerró inesperadamente al arrancar. Revisa la sintaxis."
        exit 1
    fi
    sleep 0.3
done
log "CADDY" "Reverse proxy operativo en puertos 80/443."

# ==============================================================================
# 6. MOTOR OCIS
# ==============================================================================
log "OCIS" "Inicializando entorno de almacenamiento y OIDC..."

export OCIS_BASE_DATA_PATH="/data/system/ocis"
export OCIS_URL="https://${DOMAIN_NAME}"
export OCIS_INSECURE="true"
export OCIS_EXCLUDE_RUN_SERVICES="idp"

# Driver S3NG
export STORAGE_USERS_DRIVER="s3ng"
export STORAGE_USERS_S3NG_ENDPOINT="http://127.0.0.1:8080"
export STORAGE_USERS_S3NG_REGION="default"
export STORAGE_USERS_S3NG_BUCKET="ocis"
export STORAGE_USERS_S3NG_ACCESS_KEY="dummy"
export STORAGE_USERS_S3NG_SECRET_KEY="dummy"
export STORAGE_USERS_S3NG_PUT_OBJECT_DISABLE_CONTENT_SHA256="true"

# Integración OIDC con Pocket-ID en su subdominio
export OCIS_OIDC_ISSUER="https://id.${DOMAIN_NAME}"
export WEB_OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-ocis-monolith}"
export PROXY_OIDC_ISSUER="https://id.${DOMAIN_NAME}"
export PROXY_OIDC_INSECURE="true"
export PROXY_AUTOPROVISION_ACCOUNTS="true"
export PROXY_USER_OIDC_CLAIM="preferred_username"
export OCIS_OIDC_CLAIM_USERNAME="preferred_username"
export OCIS_OIDC_CLAIM_EMAIL="email"

if [ ! -f "/data/system/ocis/config/ocis.yaml" ]; then
    log "OCIS" "Generando configuración inicial..."
    ocis init --insecure true > >(log_pipe "ocis-init") 2>&1
fi

log "OCIS" "Arrancando microservicios internos..."
ocis server > >(log_pipe "ocis") 2>&1 &
PIDS+=($!)

while ! nc -z 127.0.0.1 9200; do sleep 0.5; done

# ==============================================================================
# 6.5. RECOLECTOR DE BASURA
# ==============================================================================
/usr/local/bin/gc.sh &

log "SYSTEM" "Contenedor monolítico 100% operativo."
wait -n "${PIDS[@]}"
cleanup
