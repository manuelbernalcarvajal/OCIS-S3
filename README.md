# OCIS-S3
```
.
├── .github/
│   └── workflows/
│       └── build.yml
├── .dockerignore
├── Caddyfile
├── Dockerfile
├── entrypoint.sh
├── litestream.yml
└── compose.yml
```
```
services:
  cloud-monolith:
    build: .
    container_name: monolith-cloud
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN_NAME=nube.tudominio.com
      - RCLONE_REMOTE=b2-crypt    # Definido en rclone.conf o por vars RCLONE_*
      - OCIS_S3_BUCKET=ocis-data
      - S3_BUCKET_BACKUP=backups-sistema
    volumes:
      - ./datos_nube:/data
    # Evita que rclone se quede sin descriptores de archivo en cargas pesadas
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
```
```
/data/
├── cache/
│   └── rclone/             <-- Memoria intermedia VFS (volátil y purgable)
└── system/
    ├── caddy/              <-- Certificados SSL y estado de ACME
    ├── pocket-id/          <-- Base de datos SQLite y claves OIDC
    └── ocis/               <-- Configuración YAML y llaves de cifrado generadas
```
