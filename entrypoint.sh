#!/usr/bin/env bash
set -Eeuo pipefail

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
    log "SYSTEM" "Apagando procesos de forma ordenada..."
    kill -TERM $(jobs -p) 2>/dev/null || true
    wait
    log "SYSTEM" "Contenedor detenido limpiamente."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ---------------------------------------------------------
# 1. Rutas del volumen único
# ---------------------------------------------------------
mkdir -p /data/cache/rclone \
         /data/system/caddy \
         /data/system/pocket-id \
         /data/system/ocis/config \
         /tmp/rclone \
         /etc/app

# ---------------------------------------------------------
# 2. Generación dinámica del Caddyfile
# ---------------------------------------------------------
log "CADDY" "Configurando perfil de red (BEHIND_PROXY=${BEHIND_PROXY:-false})..."
CADDY_CONFIG="/etc/app/Caddyfile"

if [ "${BEHIND_PROXY:-false}" = "true" ]; then
    cat <<EOF > "${CADDY_CONFIG}"
{
    admin off
    auto_https off
}

:80 {
    # Pocket-ID
    handle_path /id/* {
        reverse_proxy 127.0.0.1:8081
    }

    # OCIS (Archivos y WebDAV)
    handle {
        reverse_proxy 127.0.0.1:9200 {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
}
EOF
else
    cat <<EOF > "${CADDY_CONFIG}"
{
    admin off
    email ${ACME_EMAIL:-admin@${DOMAIN_NAME}}
}

${DOMAIN_NAME} {
    storage file_system {
        root /data/system/caddy
    }

    # Protocolos modernos: HTTP/3 (QUIC) activo por defecto
    protocols h1 h2 h3

    handle_path /id/* {
        reverse_proxy 127.0.0.1:8081
    }

    handle {
        reverse_proxy 127.0.0.1:9200 {
            transport http {
                tls_insecure_skip_verify
            }
        }
    }
}
EOF
fi

# ---------------------------------------------------------
# 3. Rclone S3 Gateway (Cifrado Crypt + Purgado automático)
# ---------------------------------------------------------
log "RCLONE" "Iniciando pasarela de almacenamiento S3 local..."
cat <<EOF > /tmp/rclone/rclone.conf
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

rclone serve s3 crypt-store: \
    --config /tmp/rclone/rclone.conf \
    --addr "127.0.0.1:8080" \
    --s3-auth-builtin \
    --cache-dir "/data/cache/rclone" \
    --vfs-cache-mode full \
    --vfs-cache-min-free-space 30% \
    --vfs-cache-max-age 48h \
    --no-modtime \
    2>&1 | log_pipe "rclone" &

while ! nc -z 127.0.0.1 8080; do sleep 0.3; done

# ---------------------------------------------------------
# 4. Pocket-ID: Litestream + Auto-aprovisionamiento
# ---------------------------------------------------------
DB_PATH="/data/system/pocket-id/pocket-id.db"
FIRST_RUN=false
[ ! -f "${DB_PATH}" ] && FIRST_RUN=true

if [ -n "${S3_BUCKET_BACKUP:-}" ]; then
    litestream restore -if-replica-exists -config /etc/app/litestream.yml "${DB_PATH}" 2>&1 | log_pipe "litestream-restore" || true
    [ -f "${DB_PATH}" ] && FIRST_RUN=false
fi

litestream replicate -config /etc/app/litestream.yml 2>&1 | log_pipe "litestream" &

export DB_PATH="${DB_PATH}"
export APP_URL="https://${DOMAIN_NAME}/id"
export PORT="8081"

(cd /opt/pocket-id && ./pocket-id) 2>&1 | log_pipe "pocket-id" &
while ! nc -z 127.0.0.1 8081; do sleep 0.3; done

# Sembrado automático si la base de datos es nueva
if [ "${FIRST_RUN}" = "true" ]; then
    log "POCKET-ID" "Primera ejecución: Creando cuenta admin y cliente OIDC..."
    
    ADMIN_USER="${INITIAL_ADMIN_USER:-admin}"
    ADMIN_PASS="${INITIAL_ADMIN_PASSWORD:-Admin123456!}"
    ADMIN_MAIL="${INITIAL_ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"

    # 1. Registrar usuario base en Pocket ID
    curl -s -X POST http://127.0.0.1:8081/api/setup \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${ADMIN_USER}\",\"email\":\"${ADMIN_MAIL}\",\"password\":\"${ADMIN_PASS}\"}" >/dev/null || true

    # 2. Registrar cliente OIDC para OCIS
    curl -s -X POST http://127.0.0.1:8081/api/oidc/clients \
        -H "Content-Type: application/json" \
        -d "{
            \"id\": \"${OIDC_CLIENT_ID:-ocis-monolith}\",
            \"name\": \"ownCloud Infinite Scale\",
            \"redirectUris\": [
                \"https://${DOMAIN_NAME}/\",
                \"https://${DOMAIN_NAME}/oidc-callback.html\"
            ],
            \"isPublic\": true
        }" >/dev/null || true

    log "POCKET-ID" "Credenciales base provisionadas: ${ADMIN_USER} / [OCULTA]"
fi

# ---------------------------------------------------------
# 5. OCIS
# ---------------------------------------------------------
log "OCIS" "Iniciando motor de archivos..."
export OCIS_BASE_DATA_PATH="/data/system/ocis"
export OCIS_URL="https://${DOMAIN_NAME}"
export OCIS_INSECURE="true"

export STORAGE_USERS_DRIVER="s3"
export STORAGE_USERS_S3_ENDPOINT="http://127.0.0.1:8080"
export STORAGE_USERS_S3_REGION="default"
export STORAGE_USERS_S3_BUCKET="ocis"
export STORAGE_USERS_S3_ACCESS_KEY="dummy"
export STORAGE_USERS_S3_SECRET_KEY="dummy"

export OCIS_OIDC_ISSUER="https://${DOMAIN_NAME}/id"
export WEB_OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-ocis-monolith}"
export PROXY_OIDC_ISSUER="https://${DOMAIN_NAME}/id"

# Auto-aprovisionar cuentas al autenticar por primera vez desde Pocket ID
export PROXY_AUTOPROVISION_ACCOUNTS="true"
export PROXY_USER_OIDC_CLAIM="preferred_username"
export OCIS_OIDC_CLAIM_USERNAME="preferred_username"
export OCIS_OIDC_CLAIM_EMAIL="email"

if [ ! -f "/data/system/ocis/config/ocis.yaml" ]; then
    ocis init --insecure true 2>&1 | log_pipe "ocis-init"
fi

ocis server 2>&1 | log_pipe "ocis" &
while ! nc -z 127.0.0.1 9200; do sleep 0.5; done

# ---------------------------------------------------------
# 6. Caddy Proxy
# ---------------------------------------------------------
log "CADDY" "Publicando servicios..."
caddy run --config "${CADDY_CONFIG}" 2>&1 | log_pipe "caddy" &

log "SYSTEM" "Stack operativo al 100%."
wait -n
