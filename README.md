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
    image: ghcr.io/TU_USUARIO/TU_REPO:latest
    container_name: monolith-cloud
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - DOMAIN_NAME=nube.tudominio.com

      # Credenciales de tu proveedor S3 (B2, AWS, R2, etc.)
      - S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com
      - S3_PROVIDER=Backblaze
      - AWS_ACCESS_KEY_ID=tu_key_id
      - AWS_SECRET_ACCESS_KEY=tu_application_key
      
      # Buckets y Cifrado
      - OCIS_S3_BUCKET=mi-bucket-archivos
      - S3_BUCKET_BACKUP=mi-bucket-backups
      - CRYPT_PASSWORD=FraseUltraSeguraParaCifradoRclone
      - CRYPT_SALT=FraseSaltAdicionalOpcional

      # Cliente OIDC Pocket ID
      - OIDC_CLIENT_ID=ocis-monolith
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
