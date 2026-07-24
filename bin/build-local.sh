#!/usr/bin/env bash
#
# bin/build-local.sh — build the demo image locally, the way CI does.
#
# Reproduces drupalforge/docker_publish_action step for step, so a failure here is
# a failure there (and vice versa):
#
#   1. concatenate the action's base Dockerfile + our .devpanel/Dockerfile,
#   2. build it with the repo as context (APP_ROOT/APACHE_RUN_* build args),
#   3. start the result next to a MySQL 8 container,
#   4. exec .devpanel/init.sh          → installs Atelier from config/sync,
#   5. exec .devpanel/create_quickstart.sh → bakes the database dump,
#   6. delete files.tgz (the committed filesystem already has the files),
#   7. docker commit → a local image tag.
#
# Then run it the way DevPanel does (registry mode):
#   export ATELIER_DEMO_IMAGE=atelier-demo:local
#   docker compose -f .devcontainer/docker-compose.yml up
#
# Env:
#   TAG                image tag to commit to      (default atelier-demo:local)
#   BASE_IMAGE         DevPanel base image         (default devpanel/php:8.4-base)
#   ATELIER_IMAGE      override the pinned graft   (default: the Dockerfile's ARG)
#   DP_AI_VIRTUAL_KEY  LiteLLM trial key           (unset ⇒ keyless build)
#   DP_AI_HOST         LiteLLM proxy base URL
#   PLATFORM           e.g. linux/amd64            (default: host platform)
#   ACTION_REF         docker_publish_action ref   (default main)
#   KEEP               non-empty ⇒ leave the build containers running
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

TAG="${TAG:-atelier-demo:local}"
BASE_IMAGE="${BASE_IMAGE:-devpanel/php:8.4-base}"
ACTION_REF="${ACTION_REF:-main}"
NETWORK="atelier-demo-build"
APP_CONTAINER="atelier-demo-build-app"
DB_CONTAINER="mysql"
WORK_DIR="$(mktemp -d)"

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

cleanup() {
  local status=$?
  if [ -n "${KEEP:-}" ] && [ "$status" -ne 0 ]; then
    echo
    echo "KEEP set — leaving containers up for inspection:"
    echo "  docker exec -it $APP_CONTAINER bash"
    echo "  docker logs $APP_CONTAINER"
    echo "Clean up with: docker rm -f $APP_CONTAINER $DB_CONTAINER; docker network rm $NETWORK"
  else
    docker rm -f "$APP_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
  return $status
}
trap cleanup EXIT

# --- 1. Combined Dockerfile -------------------------------------------------
# The action cats its own base Dockerfile and our fragment together; fetch the
# real thing rather than reimplementing it, so local and CI cannot drift.
log "Fetching the action's base Dockerfile (@$ACTION_REF)"
curl -fsSL \
  "https://raw.githubusercontent.com/drupalforge/docker_publish_action/${ACTION_REF}/Dockerfile" \
  -o "$WORK_DIR/base.Dockerfile"
cp .devpanel/Dockerfile "$WORK_DIR/fragment.Dockerfile"

# The graft's image reference must be a literal — BuildKit refuses variable
# expansion in `COPY --from`. So an ATELIER_IMAGE override is applied by rewriting
# that line in this temporary copy, leaving the committed Dockerfile's pin alone.
if [ -n "${ATELIER_IMAGE:-}" ]; then
  echo "Overriding the graft pin → $ATELIER_IMAGE"
  sed -i.bak -E "s|^(COPY --from=)[^ ]+( /opt/drupal/.*)$|\1${ATELIER_IMAGE}\2|" \
    "$WORK_DIR/fragment.Dockerfile"
  grep -q "COPY --from=${ATELIER_IMAGE} " "$WORK_DIR/fragment.Dockerfile" \
    || { echo 'FATAL: could not rewrite the graft pin.' >&2; exit 1; }
fi

cat "$WORK_DIR/base.Dockerfile" "$WORK_DIR/fragment.Dockerfile" > "$WORK_DIR/Dockerfile.combined"

# --- 2. Build ---------------------------------------------------------------
log "Building $TAG on $BASE_IMAGE"
build_args=(
  --build-arg "APP_ROOT=/var/www/html"
  --build-arg "APACHE_RUN_USER=www"
  --build-arg "APACHE_RUN_GROUP=www"
  --build-arg "BASE_IMAGE=$BASE_IMAGE"
)
if [ -n "${PLATFORM:-}" ]; then
  build_args+=(--platform "$PLATFORM")
fi

docker buildx build \
  --file "$WORK_DIR/Dockerfile.combined" \
  --tag "$TAG-unprovisioned" \
  --load \
  "${build_args[@]}" \
  .

# --- 3. Run it next to MySQL ------------------------------------------------
log "Starting MySQL 8 + the built image"
docker network create "$NETWORK" >/dev/null 2>&1 || true
docker rm -f "$APP_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true

docker run -d --name "$DB_CONTAINER" --network "$NETWORK" \
  -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=drupaldb \
  -e MYSQL_USER=user \
  -e MYSQL_PASSWORD=password \
  --health-cmd='mysqladmin ping -h localhost' \
  --health-interval=5s --health-timeout=20s --health-retries=20 \
  mysql:8.0 >/dev/null

# Gate on a real connection as the application user, NOT on the container's health
# status: `mysqladmin ping` answers while MySQL is still running its bootstrap
# server, so a healthy container can still refuse connections and lack the database
# and user. Waiting on `select 1` is the only signal that means "usable".
printf 'Waiting for MySQL to accept connections'
db_ready=
for _ in $(seq 1 90); do
  if docker exec "$DB_CONTAINER" \
      mysql -uuser -ppassword -h 127.0.0.1 -e 'select 1' drupaldb >/dev/null 2>&1; then
    db_ready=1
    break
  fi
  printf '.'
  sleep 2
done
echo
[ -n "$db_ready" ] \
  || { echo 'MySQL never accepted connections.' >&2; docker logs "$DB_CONTAINER" 2>&1 | tail -20; exit 1; }

docker run -d --name "$APP_CONTAINER" --network "$NETWORK" \
  -e DP_APP_ID=atelier-demo \
  -e APP_ROOT=/var/www/html \
  -e WEB_ROOT=/var/www/html/web \
  -e APACHE_RUN_USER=www \
  -e APACHE_RUN_GROUP=www \
  -e CODES_ENABLE=no \
  "$TAG-unprovisioned" >/dev/null

# The action passes the database credentials per-exec, not to the container, so
# Apache in the build container has no database. Mirror that exactly.
cat > "$WORK_DIR/db.env" <<'EOF'
DB_HOST=mysql
DB_PORT=3306
DB_ROOT_PASSWORD=root
DB_NAME=drupaldb
DB_USER=user
DB_PASSWORD=password
DB_DRIVER=mysql
EOF

# --- 4. Install -------------------------------------------------------------
log 'Running .devpanel/init.sh (installs Atelier from config/sync)'
docker exec --env-file "$WORK_DIR/db.env" \
  -e "DP_AI_VIRTUAL_KEY=${DP_AI_VIRTUAL_KEY:-}" \
  -e "DP_AI_HOST=${DP_AI_HOST:-https://ai.drupalforge.org}" \
  "$APP_CONTAINER" sh -c '$APP_ROOT/.devpanel/init.sh'

# --- 5. Bake the database ---------------------------------------------------
log 'Running .devpanel/create_quickstart.sh (bakes the database dump)'
docker exec --env-file "$WORK_DIR/db.env" "$APP_CONTAINER" \
  bash -c '$APP_ROOT/.devpanel/create_quickstart.sh'
docker exec "$APP_CONTAINER" bash -c 'rm -f $APP_ROOT/.devpanel/dumps/files.tgz'

# --- 6. Commit --------------------------------------------------------------
log "Committing $TAG"
docker commit "$APP_CONTAINER" "$TAG" >/dev/null
docker rmi "$TAG-unprovisioned" >/dev/null 2>&1 || true

cat <<EOF

Built $TAG

Run it the way DevPanel does (registry mode — imports the baked database, then
syncs the app root into this working copy):

  export ATELIER_DEMO_IMAGE=$TAG
  docker compose -f .devcontainer/docker-compose.yml up

Then open http://localhost — admin / admin. Note the sync drops the grafted
product tree into this checkout; it is all gitignored.
EOF
