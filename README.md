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
├── gc.sh
├── litestream.yml
└── compose.yml
```
## Ejemplo de `compose.yml`

```yaml
services:
  nube:
    image: ghcr.io/manuelbernalcarvajal/ocis-s3:latest
    container_name: monolith-cloud
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    environment:
      - DOMAIN_NAME=nube.tudominio.com
      - BEHIND_PROXY=false

      # Credenciales de tu proveedor S3 (B2, AWS, R2, etc.)
      - S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com
      - S3_PROVIDER=Other
      - S3_REGION=eu-central-003
      - AWS_ACCESS_KEY_ID=tu_key_id
      - AWS_SECRET_ACCESS_KEY=tu_application_key

      # Bucket y Cifrado Rclone
      - OCIS_S3_BUCKET=mi-bucket-archivos
      - CRYPT_PASSWORD=FraseUltraSeguraParaCifradoRclone
      - CRYPT_SALT=FraseSaltAdicionalOpcional

      # Cliente OIDC Pocket ID
      - OIDC_CLIENT_ID=ocis-monolith
    volumes:
      - datos_nube:/data
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
    └── ocis/               <-- Configuración YAML y metadatos locales de OCIS
```
