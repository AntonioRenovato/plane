# CI/CD de Plane para Grupo CCIMA

## Arquitectura de imágenes

Se publican seis imágenes propias e inmutables con la etiqueta `sha-<commit completo>`: `plane-web`, `plane-admin`, `plane-space`, `plane-backend`, `plane-live` y `plane-proxy`. La misma imagen backend se reutiliza para API, worker Celery, beat y migrador, cambiando únicamente el comando. PostgreSQL, Valkey, RabbitMQ y Silo/MinIO usan versiones fijadas en Compose.

El inventario revisó los Dockerfiles de producción y desarrollo de Web, Admin, Spaces, API y Live; el Dockerfile CE del proxy; la imagen AIO; los Compose raíz, local, pruebas y CLI; los cuatro entrypoints de API/worker/beat/migrador; y el Caddyfile CE. Los Dockerfiles `.dev` y la imagen AIO no se publican porque no corresponden a la topología separada de producción. Servicios resultantes: Web (`plane-web`), Administración (`plane-admin`), Spaces (`plane-space`), API/worker/beat/migrador (`plane-backend`), Live (`plane-live`) y proxy de rutas/WebSocket (`plane-proxy`).

La aplicación productiva se ejecuta en Ubuntu `192.168.1.178`, bajo `/opt/plane-custom`, y publica Plane en `192.168.1.178:8081`. El reverse proxy Nginx externo está en `192.168.1.161`, termina TLS para `plane.grupoccima.com` y envía HTTP a `http://192.168.1.178:8081`, preservando `Host`, `X-Forwarded-Proto https`, `X-Forwarded-For` y los encabezados Upgrade/Connection de WebSocket. Antes de modificar Nginx, respaldar e inspeccionar su configuración y ejecutar `nginx -t`; este repositorio no cambia Nginx ni Certbot.

Configuración de referencia que debe adaptarse a la configuración existente, no aplicarse a ciegas:

```nginx
location / {
    proxy_pass http://192.168.1.178:8081;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
}
```

## GitHub

Variable de repositorio: `DEPLOY_ENABLED` (mantener exactamente `false` hasta la primera validación). Variables del environment protegido `plane-production`: `DEPLOY_SSH_HOST`, `DEPLOY_SSH_PORT` y `DEPLOY_SSH_USER`. Secrets del mismo environment: `DEPLOY_SSH_PRIVATE_KEY` y `DEPLOY_SSH_HOST_KEY` (línea de `known_hosts` verificada fuera de banda). Build usa el `GITHUB_TOKEN` efímero con `contents: read` y `packages: write`; Deploy usa `contents: read` y `packages: read` para comprobar las seis imágenes antes de abrir SSH.

Configure revisores obligatorios en el environment. GHCR debe permitir al servidor leer paquetes; use en `/opt/plane-custom/.env` un token de máquina con sólo `read:packages` (`GHCR_USER`, `GHCR_TOKEN`). Nunca guarde ese archivo en Git.

GitHub-hosted runners no pueden alcanzar directamente `192.168.1.178`. Antes de poner `DEPLOY_ENABLED=true`, documente y pruebe una ruta SSH privada: VPN de acceso saliente, bastion endurecido o túnel administrado iniciado desde la red interna. No abra innecesariamente el puerto 22 a Internet. Limite el firewall al origen del túnel/bastion, use un usuario de despliegue sin acceso interactivo general, una llave dedicada, `known_hosts` fijado y los permisos mínimos sobre `/opt/plane-custom`; no instale un runner privilegiado en producción. El valor de `DEPLOY_SSH_HOST` debe ser el endpoint enrutable del túnel o bastion, no la IP privada inaccesible desde GitHub. Con `DEPLOY_ENABLED=false` el job `gate` falla antes de leer secretos del environment o intentar SSH.

El workflow de despliegue debe existir en la rama predeterminada `preview` para que GitHub muestre `workflow_dispatch`. Al lanzarlo se debe seleccionar explícitamente `deploy/plane-v1.4.3`; el gate rechaza cualquier otra ref. CI se ejecuta en `preview`, desarrollo y deploy, y una ejecución manual de CI fuerza todas las verificaciones. No existe evento `push`, `pull_request`, `schedule` ni `workflow_run` en el workflow de producción, por lo que el despliegue nunca es automático.

Para incorporar exclusivamente el workflow necesario a `preview`, sin fusionar código de Plane:

1. Crear una rama temporal basada en `preview`.
2. Traer únicamente `.github/workflows/ccima-deploy.yml` desde `deploy/plane-v1.4.3` con `git checkout deploy/plane-v1.4.3 -- .github/workflows/ccima-deploy.yml`.
3. Confirmar con `git diff --cached --name-only` que ése sea el único archivo preparado.
4. Abrir un PR exclusivo hacia `preview`, exigir revisión y no incluir merges de desarrollo o deploy.
5. Tras aprobarlo, ejecutar manualmente el workflow seleccionando la ref `deploy/plane-v1.4.3`.

El gate valida que el SHA solicitado sea un commit completo y ancestro de la rama de despliegue. Después, `verify-images` comprueba en GHCR las seis etiquetas inmutables (`web`, `admin`, `space`, `backend`, `live`, `proxy`). Sólo entonces se solicita aprobación del environment `plane-production` y se habilitan los secretos SSH.

## Primera instalación

1. Crear `/opt/plane-custom/releases/incoming` y asignarlo al usuario de despliegue sin alterar otros proyectos.
2. Copiar `.env.production.example` a `/opt/plane-custom/.env`, generar secretos largos y permisos `0600`.
3. Copiar Compose, `deploy.sh` y `rollback.sh`; hacer ejecutables los scripts.
4. Verificar que `8081` esté libre y que los volúmenes `plane-custom-*` no colisionen.
5. Autenticar GHCR, validar `docker compose ... config`, descargar las seis imágenes del SHA aprobado y asegurar un backup recuperable de PostgreSQL.
6. Ejecutar `CONFIRM_DB_BACKUP=yes /opt/plane-custom/releases/incoming/deploy.sh sha-<commit>` desde una sesión controlada para la primera validación.
7. Probar desde el servidor de aplicaciones `127.0.0.1:8081`, desde Nginx `192.168.1.178:8081` y después el dominio HTTPS, login, cargas, Spaces, administración y colaboración Live/WebSocket. Sólo entonces habilitar el workflow manual.

## Despliegue y recuperación

El script usa `flock`, valida dependencias/Compose, exige `.env` con modo `0600` y sin marcadores `CHANGE_ME`, descarga imágenes, exige confirmación del backup, ejecuta el migrador una sola vez y levanta exclusivamente el proyecto `plane-custom`. Durante un máximo total de 300 segundos reintenta cada cinco segundos tanto `/` como `/api/instances/`; sólo después de que ambos respondan correctamente registra `IMAGE_TAG`, `DEPLOYED_VERSION` e historial. No usa `docker system prune`, `docker compose down`, eliminación de volúmenes ni `--remove-orphans`.

Para volver a imágenes anteriores, después de comprobar compatibilidad de esquema o restaurar el backup correspondiente: `CONFIRM_ROLLBACK=yes CONFIRM_SCHEMA_COMPATIBLE=yes /opt/plane-custom/rollback.sh sha-<commit>`. Una migración de esquema puede hacer que el rollback de imágenes sea insuficiente o destructivo; en ese caso detenga el cambio, restaure el backup compatible y luego use las imágenes correspondientes. Ensaye restauraciones antes de producción.

## Activación

Proteja `deploy/plane-v1.4.3`, exija `CCIMA CI / required`, revise y fusione por el proceso corporativo. El push construye las imágenes. El workflow de producción verifica las seis etiquetas GHCR antes de acceder al environment. Ejecute manualmente `CCIMA Deploy Production` seleccionando esa rama, con el SHA completo y `DEPLOY`; requiere `DEPLOY_ENABLED=true`, backup confirmado y aprobación del environment.

Para validación local en Ubuntu: `sudo apt-get install shellcheck`; Actionlint puede instalarse desde su release oficial (`rhysd/actionlint`) y ejecutarse como `actionlint .github/workflows/ccima-*.yml`. No descargue binarios sin verificar checksum/firma y procedencia.
