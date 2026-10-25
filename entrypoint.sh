#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# 0. LOGGING Y CONTROL DE SEÑALES
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
    log "SYSTEM" "Señal de parada recibida. Cerrando servicios..."
    kill -TERM $(jobs -p) 2>/dev/null || true
    wait
    log "SYSTEM" "Contenedor apagado limpiamente."
    exit 0
}
trap cleanup SIGTERM SIGINT

# ==============================================================================
# 1. PARCHE DE RED (Anti-Hairpin NAT) Y DIRECTORIOS
# ==============================================================================
# Resuelve el dominio dentro del contenedor a localhost para evitar caídas
# si el firewall exterior o el router no soportan NAT Loopback
if ! grep -q "${DOMAIN_NAME}" /etc/hosts 2>/dev/null; then
    echo "127.0.0.1 ${DOMAIN_NAME}" >> /etc/hosts 2>/dev/null || true
    log "SYSTEM" "Bypass DNS local aplicado para ${DOMAIN_NAME}."
fi

mkdir -p /data/cache/rclone \
         /data/system/caddy \
         /data/system/pocket-id \
         /data/system/ocis/config \
         /tmp/rclone \
         /etc/app

# ==============================================================================
# 2. GENERACIÓN DINÁMICA DE CADDYFILE
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
else
    log "CADDY" "Modo directo activo (ACME + TLS 1.3 / QUIC)."
    cat <<EOF > "${CADDY_CONFIG}"
{
    admin off
    email ${ACME_EMAIL:-admin@${DOMAIN_NAME}}
}

${DOMAIN_NAME} {
    storage file_system {
        root /data/system/caddy
    }

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

# ==============================================================================
# 3. RCLONE S3 GATEWAY (PRIMERO EN ARRANCAR)
# ==============================================================================
log "RCLONE" "Escribiendo configuración en memoria..."
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

log "RCLONE" "Iniciando pasarela S3 en 127.0.0.1:8080..."
rclone serve s3 crypt-store: \
    --config /tmp/rclone/rclone.conf \
    --addr "127.0.0.1:8080" \
    --auth-key "dummy,dummy" \
    --cache-dir "/data/cache/rclone" \
    --vfs-cache-mode full \
    --vfs-cache-min-free-space 30% \
    --vfs-cache-max-age 48h \
    --vfs-fast-fingerprint \
    --no-modtime \
    2>&1 | log_pipe "rclone" &

while ! nc -z 127.0.0.1 8080; do sleep 0.3; done
log "RCLONE" "Pasarela operativa con credenciales explícitas autorizadas."

# ==============================================================================
# 4. LITESTREAM + POCKET-ID (DESPUÉS DE RCLONE)
# ==============================================================================
DB_PATH="/data/system/pocket-id/pocket-id.db"
FIRST_RUN=false
[ ! -f "${DB_PATH}" ] && FIRST_RUN=true

# Litestream consulta al Rclone local que ya está en escucha
log "LITESTREAM" "Comprobando réplica cifrada de SQLite..."
litestream restore -if-replica-exists -config /etc/app/litestream.yml "${DB_PATH}" 2>&1 | log_pipe "litestream-sync" || true
[ -f "${DB_PATH}" ] && FIRST_RUN=false

litestream replicate -config /etc/app/litestream.yml 2>&1 | log_pipe "litestream" &

export DB_PATH="${DB_PATH}"
export APP_URL="https://${DOMAIN_NAME}/id"
export PORT="8081"

(cd /opt/pocket-id && ./pocket-id) 2>&1 | log_pipe "pocket-id" &
while ! nc -z 127.0.0.1 8081; do sleep 0.3; done

# Registro automático en Pocket-ID con diagnóstico de respuesta
if [ "${FIRST_RUN}" = "true" ]; then
    log "POCKET-ID" "Configurando admin y cliente OIDC iniciales..."
    
    ADMIN_USER="${INITIAL_ADMIN_USER:-admin}"
    ADMIN_PASS="${INITIAL_ADMIN_PASSWORD:-Admin123456!}"
    ADMIN_MAIL="${INITIAL_ADMIN_EMAIL:-admin@${DOMAIN_NAME}}"

    # 1. Crear usuario Admin
    RESP_USER=$(curl -s -o /tmp/resp_user.json -w "%{http_code}" -X POST http://127.0.0.1:8081/api/setup \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${ADMIN_USER}\",\"email\":\"${ADMIN_MAIL}\",\"password\":\"${ADMIN_PASS}\"}")

    if [ "${RESP_USER}" -ge 200 ] && [ "${RESP_USER}" -lt 300 ]; then
        log "POCKET-ID" "Usuario Admin creado correctamente."
    else
        log "POCKET-ID" "Aviso en setup (HTTP ${RESP_USER}): $(cat /tmp/resp_user.json 2>/dev/null)"
    fi

    # 2. Registrar cliente OCIS
    RESP_CLIENT=$(curl -s -o /tmp/resp_client.json -w "%{http_code}" -X POST http://127.0.0.1:8081/api/oidc/clients \
        -H "Content-Type: application/json" \
        -d "{
            \"id\": \"${OIDC_CLIENT_ID:-ocis-monolith}\",
            \"name\": \"ownCloud Infinite Scale\",
            \"redirectUris\": [
                \"https://${DOMAIN_NAME}/\",
                \"https://${DOMAIN_NAME}/oidc-callback.html\"
            ],
            \"isPublic\": true
        }")

    if [ "${RESP_CLIENT}" -ge 200 ] && [ "${RESP_CLIENT}" -lt 300 ]; then
        log "POCKET-ID" "Cliente OIDC registrado correctamente."
    else
        log "POCKET-ID" "Aviso en registro OIDC (HTTP ${RESP_CLIENT}): $(cat /tmp/resp_client.json 2>/dev/null)"
    fi
fi

# ==============================================================================
# 5. NÚCLEO OCIS
# ==============================================================================
log "OCIS" "Inicializando entorno de almacenamiento y OIDC..."

export OCIS_BASE_DATA_PATH="/data/system/ocis"
export OCIS_URL="https://${DOMAIN_NAME}"
export OCIS_INSECURE="true"

# Driver S3 apuntando a rclone
export STORAGE_USERS_DRIVER="s3"
export STORAGE_USERS_S3_ENDPOINT="http://127.0.0.1:8080"
export STORAGE_USERS_S3_REGION="default"
export STORAGE_USERS_S3_BUCKET="ocis"
export STORAGE_USERS_S3_ACCESS_KEY="dummy"
export STORAGE_USERS_S3_SECRET_KEY="dummy"

# OIDC con Pocket-ID
export OCIS_OIDC_ISSUER="https://${DOMAIN_NAME}/id"
export WEB_OIDC_CLIENT_ID="${OIDC_CLIENT_ID:-ocis-monolith}"
export PROXY_OIDC_ISSUER="https://${DOMAIN_NAME}/id"
export PROXY_OIDC_INSECURE="true"
export PROXY_AUTOPROVISION_ACCOUNTS="true"
export PROXY_USER_OIDC_CLAIM="preferred_username"
export OCIS_OIDC_CLAIM_USERNAME="preferred_username"
export OCIS_OIDC_CLAIM_EMAIL="email"

if [ ! -f "/data/system/ocis/config/ocis.yaml" ]; then
    log "OCIS" "Generando configuración inicial mediante 'ocis init'..."
    ocis init --insecure true 2>&1 | log_pipe "ocis-init"
fi

log "OCIS" "Arrancando microservicios internos..."
ocis server 2>&1 | log_pipe "ocis" &
while ! nc -z 127.0.0.1 9200; do sleep 0.5; done

# ==============================================================================
# 6. ENTRADA PÚBLICA CADDY
# ==============================================================================
log "CADDY" "Levantando reverse proxy..."
caddy run --config "${CADDY_CONFIG}" 2>&1 | log_pipe "caddy" &

log "SYSTEM" "Contenedor monolítico 100% operativo."
wait -n
