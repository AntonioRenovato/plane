#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT=/opt/plane-custom
readonly COMPOSE="$ROOT/docker-compose.production.yml"
readonly ENV_FILE="$ROOT/.env"
readonly LOCK_FILE="$ROOT/deploy.lock"
readonly VERSION_FILE="$ROOT/DEPLOYED_VERSION"
readonly HISTORY_FILE="$ROOT/deploy-history.log"
readonly NEW_TAG="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ "$NEW_TAG" =~ ^sha-[0-9a-f]{40}$ ]] || die "usage: deploy.sh sha-<40-character-commit>"
command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null || die "docker compose v2 is required"
command -v curl >/dev/null || die "curl is required"
command -v flock >/dev/null || die "flock is required"
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE is missing"
[[ "$(stat -c '%a' "$ENV_FILE")" == "600" ]] || die "$ENV_FILE must have mode 0600"
grep -q 'CHANGE_ME' "$ENV_FILE" && die "$ENV_FILE still contains CHANGE_ME placeholders"
[[ "${CONFIRM_DB_BACKUP:-}" == "yes" ]] || die "set CONFIRM_DB_BACKUP=yes after verifying a current database backup"

exec 9>"$LOCK_FILE"
flock -n 9 || die "another Plane deployment is running"

install -m 640 "$ROOT/releases/incoming/docker-compose.production.yml" "$COMPOSE"
install -m 750 "$ROOT/releases/incoming/rollback.sh" "$ROOT/rollback.sh"
old_tag="$(sed -n 's/^IMAGE_TAG=//p' "$ENV_FILE" | tail -1)"
[[ -n "$old_tag" ]] || die "IMAGE_TAG is missing from $ENV_FILE"
migration_completed=0

cleanup() {
  rc=$?
  if (( rc != 0 )); then
    echo "Deployment failed; declared IMAGE_TAG remains $old_tag." >&2
    if (( migration_completed == 1 )); then
      echo "The migration completed. Do not roll images back until schema compatibility is verified or the database backup is restored." >&2
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

docker login ghcr.io -u "$(sed -n 's/^GHCR_USER=//p' "$ENV_FILE" | tail -1)" --password-stdin < <(sed -n 's/^GHCR_TOKEN=//p' "$ENV_FILE" | tail -1)
IMAGE_TAG="$NEW_TAG" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" config --quiet
IMAGE_TAG="$NEW_TAG" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" pull
IMAGE_TAG="$NEW_TAG" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" --profile migration run --rm migrator
migration_completed=1
IMAGE_TAG="$NEW_TAG" docker compose --env-file "$ENV_FILE" -f "$COMPOSE" up -d

for _ in $(seq 1 30); do
  curl -fsS -H 'Host: plane.grupoccima.com' http://127.0.0.1:8081/ >/dev/null && healthy=1 && break
  sleep 5
done
[[ "${healthy:-0}" == 1 ]] || die "health check failed on 127.0.0.1:8081"
curl --retry 10 --retry-delay 3 --retry-all-errors -fsS -H 'Host: plane.grupoccima.com' http://127.0.0.1:8081/api/instances/ >/dev/null || die "API health check failed"

sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=$NEW_TAG/" "$ENV_FILE"
printf '%s\n' "$NEW_TAG" > "$VERSION_FILE"
printf '%s deployed=%s previous=%s user=%s\n' "$(date -u +%FT%TZ)" "$NEW_TAG" "$old_tag" "${USER:-unknown}" >> "$HISTORY_FILE"
trap - EXIT
echo "Deployed $NEW_TAG"
