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
      # --- DOMINIO Y RED ---
      - DOMAIN_NAME=nube.tudominio.com

      # --- CABLE 1: REMOTO B2 Y CIFRADO (RCLONE) ---
      # Remoto crudo hacia Backblaze B2
      - RCLONE_CONFIG_B2RAW_TYPE=b2
      - RCLONE_CONFIG_B2RAW_ACCOUNT=tu_application_key_id
      - RCLONE_CONFIG_B2RAW_KEY=tu_application_key
      - RCLONE_CONFIG_B2RAW_HARD_DELETE=true
      # Capa de cifrado transparente sobre el bucket de B2
      - RCLONE_CONFIG_B2CRYPT_TYPE=crypt
      - RCLONE_CONFIG_B2CRYPT_REMOTE=b2raw:mi-bucket-ocis/cifrado
      - RCLONE_CONFIG_B2CRYPT_PASSWORD_SALT=tu_salt_secreto_generado
      - RCLONE_CONFIG_B2CRYPT_PASSWORD=tu_password_secreto_generado

      # --- CABLE 2: PASARELA S3 LOCAL (RCLONE <-> OCIS) ---
      - LOCAL_S3_USER=ocis_s3_admin
      - LOCAL_S3_PASSWORD=clave_aleatoria_s3_muy_larga_123
      - LOCAL_S3_PORT=8080

      # --- CABLE 3: IDENTIDAD OIDC (POCKET ID <-> OCIS) ---
      - OIDC_CLIENT_ID=ocis-web
      - OIDC_CLIENT_SECRET=clave_secreta_oidc_para_comunicacion_interna
      - POCKETID_ADMIN_EMAIL=tu-email@tudominio.com

      # --- BACKUPS LITESTREAM (METADATOS Y USUARIOS A S3) ---
      - S3_ENDPOINT=https://s3.eu-central-003.backblazeb2.com
      - S3_BUCKET_BACKUP=mi-bucket-backups
      - AWS_ACCESS_KEY_ID=tu_application_key_id
      - AWS_SECRET_ACCESS_KEY=tu_application_key

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
