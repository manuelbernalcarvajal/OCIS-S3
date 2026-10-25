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
  nube:
    image: ghcr.io/TU_USUARIO_GITHUB/NOMBRE_DEL_REPO:latest
    container_name: monolith-cloud
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      # Dominio y Routing
      - DOMAIN_NAME=nube.tudominio.com
      
      # Pocket ID / Litestream
      - S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com # Tu endpoint
      - S3_BUCKET_BACKUP=mi-bucket-backups
      - AWS_ACCESS_KEY_ID=tu_key_id
      - AWS_SECRET_ACCESS_KEY=tu_application_key
      
      # Rclone (Pasarela S3 cifrada)
      - RCLONE_REMOTE=b2-crypt
      - OCIS_S3_BUCKET=ocis-data
    volumes:
      - ./datos_nube:/data
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
