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
/data/
├── cache/
│   └── rclone/             <-- Memoria intermedia VFS (volátil y purgable)
└── system/
    ├── caddy/              <-- Certificados SSL y estado de ACME
    ├── pocket-id/          <-- Base de datos SQLite y claves OIDC
    └── ocis/               <-- Configuración YAML y llaves de cifrado generadas
```
