#!/usr/bin/env bash
set -Eeuo pipefail

log() {
    printf "[%-12s] %s\n" "GC" "$*"
}

log_pipe() {
    local service="$1"
    while IFS= read -r line; do
        printf "[%-12s] %s\n" "${service}" "${line}"
    done
}

# Función en Bash para medir % de CPU incluyendo iowait, irq, softirq y steal
get_cpu_usage() {
    read -r _ u1 n1 s1 idle1 iow1 irq1 sirq1 stl1 _ < /proc/stat
    local total1=$((u1 + n1 + s1 + idle1 + iow1 + irq1 + sirq1 + stl1))
    sleep 1
    read -r _ u2 n2 s2 idle2 iow2 irq2 sirq2 stl2 _ < /proc/stat
    local total2=$((u2 + n2 + s2 + idle2 + iow2 + irq2 + sirq2 + stl2))

    local total_delta=$((total2 - total1))
    local idle_delta=$((idle2 - idle1))

    if [ "${total_delta}" -gt 0 ]; then
        echo "$(( (total_delta - idle_delta) * 100 / total_delta ))"
    else
        echo "0"
    fi
}

log "Demonio de mantenimiento iniciado. Esperando 15 minutos de cortesía..."
sleep 900

while true; do
    log "Comprobando actividad del sistema antes del ciclo..."
    CPU_LOAD=$(get_cpu_usage)
    log "Uso de CPU actual: ${CPU_LOAD}% (Límite: 20%)"

    if [ "${CPU_LOAD}" -ge 20 ]; then
        log "Servidor bajo carga activa (${CPU_LOAD}%). Aplazando 10 minutos..."
        sleep 600
        continue
    fi

    log "Condiciones óptimas. Iniciando mantenimiento higiénico..."

    # 1. Purgar subidas incompletas en S3 / Backblaze usando la configuración persistente en /etc/app
    if [ -f "/etc/app/rclone.conf" ] && [ -n "${OCIS_S3_BUCKET:-}" ]; then
        log "Limpiando fragmentos 'multipart' huérfanos en S3..."
        rclone cleanup --config /etc/app/rclone.conf "s3-raw:${OCIS_S3_BUCKET}" 2>&1 | log_pipe "gc-rclone" || true
    fi

    # 2. Borrar archivos temporales de /tmp con más de 3 días de antigüedad (basado en mtime)
    log "Eliminando temporales locales antiguos en /tmp..."
    find /tmp -mindepth 1 -type f -mtime +3 -delete 2>/dev/null || true

    # 3. Comprobar salud de los puertos internos (Rclone, Pocket-ID, OCIS)
    for port in 8080 8081 9200; do
        if ! nc -z 127.0.0.1 "${port}"; then
            log "ALERTA: El servicio interno en el puerto ${port} no responde."
        fi
    done

    log "Mantenimiento finalizado con éxito. Próximo chequeo en 3 días."
    sleep 72h
done
