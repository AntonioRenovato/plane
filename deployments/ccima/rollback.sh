#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT=/opt/plane-custom
readonly COMPOSE="$ROOT/docker-compose.production.yml"
readonly ENV_FILE="$ROOT/.env"
readonly TARGET="${1:-}"
[[ "$TARGET" =~ ^sha-[0-9a-f]{40}$ ]] || { echo "usage: rollback.sh sha-<40-character-commit>" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is not installed" >&2; exit 1; }
docker compose version >/dev/null || { echo "docker compose v2 is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v flock >/dev/null || { echo "flock is required" >&2; exit 1; }
[[ -f "$ENV_FILE" && -f "$COMPOSE" ]] || { echo "production files are missing" >&2; exit 1; }
[[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] || { echo "$ENV_FILE must have mode 0600" >&2; exit 1; }
exec 9>"$ROOT/deploy.lock"
flock -n 9 || { echo "another Plane deployment is running" >&2; exit 1; }

echo "WARNING: image rollback does not reverse database migrations. Restore a compatible database backup when schema changes are not backward-compatible."
[[ "${CONFIRM_ROLLBACK:-}" == "yes" ]] || { echo "set CONFIRM_ROLLBACK=yes to continue" >&2; exit 1; }
[[ "${CONFIRM_SCHEMA_COMPATIBLE:-}" == "yes" ]] || { echo "set CONFIRM_SCHEMA_COMPATIBLE=yes after verifying schema compatibility or restoring the matching backup" >&2; exit 1; }
docker login ghcr.io -u "$(sed -n 's/^GHCR_USER=//p' "$ENV_FILE" | tail -1)" --password-stdin < <(sed -n 's/^GHCR_TOKEN=//p' "$ENV_FILE" | tail -1)
IMAGE_TAG="$TARGET" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" config --quiet
IMAGE_TAG="$TARGET" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" pull
IMAGE_TAG="$TARGET" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" up -d
curl --retry 20 --retry-delay 5 --retry-all-errors -fsS -H 'Host: plane.grupoccima.com' http://127.0.0.1:8081/ >/dev/null
curl --retry 10 --retry-delay 3 --retry-all-errors -fsS -H 'Host: plane.grupoccima.com' http://127.0.0.1:8081/api/instances/ >/dev/null
sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$TARGET/" "$ENV_FILE"
printf '%s\n' "$TARGET" > "$ROOT/DEPLOYED_VERSION"
printf '%s rollback=%s user=%s\n' "$(date -u +%FT%TZ)" "$TARGET" "${USER:-unknown}" >> "$ROOT/deploy-history.log"
