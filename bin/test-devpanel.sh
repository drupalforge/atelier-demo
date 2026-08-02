#!/usr/bin/env bash
#
# bin/test-devpanel.sh — run the demo image the way DevPanel does, locally.
#
# This exists because we cannot read the Kubernetes logs of a hosted Drupal Forge
# instance. Everything DevPanel does to our image can be reproduced here, against
# the very image it runs, so a "the deployment is broken" report can be bisected
# locally instead of guessed at.
#
# Scenarios (all run by default; pass names to pick):
#   plain    start the image, run init-container.sh, check HTTP
#   volume   the two-phase volume dance: image app root → ../build volume, then
#            that volume mounted AT the app root (what DevPanel actually serves)
#   codes    CODES_ENABLE=yes, DevPanel's default (code-server alongside Apache)
#   hostname DP_HOSTNAME set, then request with a foreign Host header — the shape
#            of a Kubernetes probe. Catches trusted_host_patterns 400s.
#   nodb     init-container.sh with the database unreachable — checks that it fails
#            loudly and leaves a FAILED marker in logs/ rather than dying silently
#
# Usage:
#   ./bin/test-devpanel.sh                       # published image, all scenarios
#   IMAGE=atelier-demo:local ./bin/test-devpanel.sh
#   ./bin/test-devpanel.sh hostname nodb
#
set -uo pipefail

IMAGE="${IMAGE:-drupalforge/atelier-demo:main}"
NET=dp-test
PORT="${PORT:-8090}"
DUMMY_KEY="${DP_AI_VIRTUAL_KEY:-sk-dummy-not-a-real-key}"
SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(plain volume freshdb codes hostname nodb)

pass=0; failed=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed+1)); }
hdr()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

DB_ENV=(-e DB_HOST=dpt-db -e DB_PORT=3306 -e DB_NAME=drupaldb
        -e DB_USER=user -e DB_PASSWORD=password -e DB_DRIVER=mysql)
APP_ENV=(-e DP_APP_ID=atelier-demo -e APP_ROOT=/var/www/html
         -e WEB_ROOT=/var/www/html/web -e APACHE_RUN_USER=www
         -e APACHE_RUN_GROUP=www -e "DP_AI_VIRTUAL_KEY=$DUMMY_KEY"
         -e DP_AI_HOST=https://ai.drupalforge.org)

cleanup() {
  docker rm -f dpt-db dpt-app dpt-p1 dpt-p2 >/dev/null 2>&1
  docker volume rm dpt-vol >/dev/null 2>&1
  docker network rm $NET >/dev/null 2>&1
}
trap cleanup EXIT
cleanup

docker network create $NET >/dev/null 2>&1

start_db() {
  docker rm -f dpt-db >/dev/null 2>&1
  docker run -d --name dpt-db --network $NET \
    -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=drupaldb \
    -e MYSQL_USER=user -e MYSQL_PASSWORD=password mysql:8.0 >/dev/null
  printf '  waiting for mysql'
  for _ in $(seq 1 90); do
    docker exec dpt-db mysql -uuser -ppassword -h127.0.0.1 -e 'select 1' drupaldb \
      >/dev/null 2>&1 && { echo ' ready'; return 0; }
    printf '.'; sleep 2
  done
  echo; bad 'mysql never came up'; return 1
}

# Report a container's own logs/ directory — the same evidence trail we rely on
# when diagnosing a hosted instance.
show_logs_dir() {
  local c="$1"
  docker exec "$c" bash -lc 'ls -1t $APP_ROOT/logs/ 2>/dev/null | head -5' 2>/dev/null \
    | sed 's/^/       logs\//'
  if docker exec "$c" bash -lc 'ls $APP_ROOT/logs/FAILED-*.log >/dev/null 2>&1' 2>/dev/null; then
    printf '       \033[31ma FAILED-*.log marker is present\033[0m\n'
  fi
}

http() { curl -s -o /dev/null -w '%{http_code}' "$@" 2>/dev/null; }

run_plain() {
  hdr 'plain — start the image and run init-container.sh'
  start_db || return
  docker rm -f dpt-app >/dev/null 2>&1
  docker run -d --name dpt-app --network $NET -p "$PORT:80" \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no "$IMAGE" >/dev/null
  sleep 6
  if docker exec dpt-app bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/tmp/dpt-plain.log 2>&1; then
    ok 'init-container.sh exited 0'
  else
    bad "init-container.sh failed — tail:"; tail -12 /tmp/dpt-plain.log | sed 's/^/       /'
  fi
  show_logs_dir dpt-app
  local code; code=$(http "http://localhost:$PORT/")
  [ "$code" = 200 ] && ok "homepage → 200" || bad "homepage → $code"
  docker exec dpt-app bash -lc 'grep -q "<title>Atelier" <(curl -s http://127.0.0.1/)' 2>/dev/null \
    && ok 'homepage is the branded Atelier front page' || bad 'homepage is not the branded front page'
}

run_volume() {
  hdr 'volume — the two-phase app-root volume dance DevPanel performs'
  start_db || return
  docker volume rm dpt-vol >/dev/null 2>&1; docker volume create dpt-vol >/dev/null
  docker rm -f dpt-p1 dpt-p2 >/dev/null 2>&1

  echo '  phase 1: image app root → volume mounted at ../build'
  docker run -d --name dpt-p1 --network $NET -v dpt-vol:/var/www/build \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no -e DB_SYNC_VOL=yes "$IMAGE" >/dev/null
  sleep 6
  if docker exec dpt-p1 bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/tmp/dpt-p1.log 2>&1; then
    ok 'phase 1 init-container.sh exited 0'
  else
    bad 'phase 1 failed — tail:'; tail -12 /tmp/dpt-p1.log | sed 's/^/       /'
  fi
  docker exec dpt-p1 bash -lc 'test -d /var/www/build/vendor && test -f /var/www/build/web/sites/default/settings.php' \
    && ok 'app root landed in the volume (vendor + settings.php)' \
    || bad 'the volume is missing vendor/ or settings.php'

  echo '  phase 2: that volume mounted AT the app root (what DevPanel serves)'
  docker run -d --name dpt-p2 --network $NET -p "$((PORT+1)):80" -v dpt-vol:/var/www/html \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no "$IMAGE" >/dev/null
  sleep 8
  if docker exec dpt-p2 bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/tmp/dpt-p2.log 2>&1; then
    ok 'phase 2 init-container.sh exited 0'
  else
    bad 'phase 2 failed — tail:'; tail -12 /tmp/dpt-p2.log | sed 's/^/       /'
  fi
  show_logs_dir dpt-p2
  local code; code=$(http "http://localhost:$((PORT+1))/")
  [ "$code" = 200 ] && ok 'homepage from the volume → 200' || bad "homepage from the volume → $code"
}

run_codes() {
  hdr "codes — CODES_ENABLE=yes (DevPanel's default)"
  start_db || return
  docker rm -f dpt-app >/dev/null 2>&1
  docker run -d --name dpt-app --network $NET -p "$PORT:80" \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=yes "$IMAGE" >/dev/null
  sleep 20
  local state; state=$(docker inspect -f '{{.State.Status}}' dpt-app 2>/dev/null)
  [ "$state" = running ] && ok 'container still running with code-server enabled' \
    || bad "container is $state (exit $(docker inspect -f '{{.State.ExitCode}}' dpt-app 2>/dev/null))"
  docker exec dpt-app bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/dev/null 2>&1
  local code; code=$(http "http://localhost:$PORT/")
  [ "$code" = 200 ] && ok 'homepage → 200' || bad "homepage → $code"
}

run_hostname() {
  hdr 'hostname — DP_HOSTNAME set, request arriving with a foreign Host (probe shape)'
  start_db || return
  docker rm -f dpt-app >/dev/null 2>&1
  docker run -d --name dpt-app --network $NET -p "$PORT:80" \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no \
    -e DP_HOSTNAME=atelier-demo.drupalforge.org "$IMAGE" >/dev/null
  sleep 6
  docker exec dpt-app bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/dev/null 2>&1
  local public probe podip
  public=$(http -H 'Host: atelier-demo.drupalforge.org' "http://localhost:$PORT/")
  probe=$(http "http://localhost:$PORT/")
  podip=$(http -H 'Host: 10.0.0.5' "http://localhost:$PORT/")
  [ "$public" = 200 ] && ok "public hostname → 200" || bad "public hostname → $public"
  # These two are what a Kubernetes readiness/liveness probe looks like. A 400 here
  # means the pod never goes ready and the deployment fails with no app-level error.
  [ "$probe" = 200 ] && ok "Host: localhost → 200 (probes will pass)" \
    || bad "Host: localhost → $probe (a k8s probe would fail; trusted_host_patterns too strict)"
  [ "$podip" = 200 ] && ok "Host: pod IP → 200" \
    || bad "Host: pod IP → $podip (a k8s probe would fail; trusted_host_patterns too strict)"
}

run_freshdb() {
  hdr 'freshdb — volume app root + an EMPTY database (the hosted failure)'
  # This is what broke the first hosted instance. DevPanel syncs the app root into a
  # volume EXCLUDING .devpanel/dumps, then serves a container whose database is
  # empty. With no dump in the app root and no site in the database, Drupal falls
  # through to /core/install.php and the public sees a bare install wizard.
  start_db || return
  docker volume rm dpt-vol >/dev/null 2>&1; docker volume create dpt-vol >/dev/null
  docker rm -f dpt-p1 dpt-p2 >/dev/null 2>&1

  echo '  phase 1: populate the volume from the image'
  docker run -d --name dpt-p1 --network $NET -v dpt-vol:/var/www/build \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no -e DB_SYNC_VOL=yes "$IMAGE" >/dev/null
  sleep 6
  docker exec dpt-p1 bash -lc '$APP_ROOT/.devpanel/init-container.sh' >/dev/null 2>&1
  docker exec dpt-p1 bash -lc 'test -e /var/www/build/.devpanel/dumps/db.sql.gz' 2>/dev/null \
    && printf '       (note: the dump IS in the volume)\n' \
    || ok 'the volume has no in-tree dump (as DevPanel leaves it)'

  echo '  phase 2: throw the database away, serve from the volume'
  docker rm -f dpt-db >/dev/null 2>&1
  start_db || return
  docker run -d --name dpt-p2 --network $NET -p "$((PORT+2)):80" -v dpt-vol:/var/www/html \
    "${APP_ENV[@]}" "${DB_ENV[@]}" -e CODES_ENABLE=no "$IMAGE" >/dev/null

  # POLL, do not sleep a fixed interval. This was `sleep 25`, and the seed in
  # custom_package_installer.sh takes about 40s on a developer laptop — so the
  # scenario reported `homepage → 000` on a container that was seeding correctly
  # and would answer 200 fifteen seconds later. Both assertions then failed, on
  # the PUBLISHED image as well as a local build, which makes the one scenario
  # that reproduces a real hosted outage read as permanently broken — and a test
  # that always fails is a test nobody reads. Waiting for the condition instead of
  # guessing at its duration also stops this from re-breaking on a slower machine.
  printf '  waiting for the startup seed'
  for _ in $(seq 1 40); do
    [ "$(http "http://localhost:$((PORT+2))/")" = 200 ] && break
    printf '.'
    sleep 3
  done
  echo

  local code redirect
  code=$(http "http://localhost:$((PORT+2))/")
  redirect=$(curl -s -o /dev/null -w '%{redirect_url}' "http://localhost:$((PORT+2))/" 2>/dev/null)
  case "$redirect" in
    *install.php*) bad "homepage redirects to $redirect — the public would see the Drupal installer" ;;
    *) [ "$code" = 200 ] && ok 'homepage → 200 (recovered without any dump in the app root)' \
         || bad "homepage → $code (redirect: ${redirect:-none})" ;;
  esac
  docker exec dpt-p2 bash -lc 'curl -s http://127.0.0.1/ | grep -q "<title>Atelier"' 2>/dev/null \
    && ok 'and it is the branded Atelier front page' || bad 'not the branded front page'
  show_logs_dir dpt-p2
}

run_nodb() {
  hdr 'nodb — init-container.sh with the database unreachable'
  docker rm -f dpt-app >/dev/null 2>&1
  docker run -d --name dpt-app --network $NET \
    "${APP_ENV[@]}" -e CODES_ENABLE=no \
    -e DB_HOST=nonexistent-db -e DB_PORT=3306 -e DB_NAME=drupaldb \
    -e DB_USER=user -e DB_PASSWORD=password -e DB_DRIVER=mysql "$IMAGE" >/dev/null
  sleep 5
  # Expected: a non-zero exit, a clear message, and a marker left behind. Keep the
  # wait short so the test does not sit through the full retry budget.
  docker exec -e DP_DB_WAIT_TRIES=2 dpt-app bash -lc \
    'sed -i "s/^dp_wait_for_db$/dp_wait_for_db 2/" $APP_ROOT/.devpanel/init-container.sh; $APP_ROOT/.devpanel/init-container.sh' \
    >/tmp/dpt-nodb.log 2>&1
  local rc=$?
  [ $rc -ne 0 ] && ok "exited non-zero ($rc) instead of pretending to succeed" \
    || bad 'exited 0 despite having no database'
  grep -q 'never accepted connections' /tmp/dpt-nodb.log \
    && ok 'printed a clear diagnosis of the database being unreachable' \
    || { bad 'no clear diagnosis in the output — tail:'; tail -8 /tmp/dpt-nodb.log | sed 's/^/       /'; }
  docker exec dpt-app bash -lc 'ls $APP_ROOT/logs/FAILED-init-container.log' >/dev/null 2>&1 \
    && ok 'left logs/FAILED-init-container.log for whoever opens the instance' \
    || bad 'left no FAILED marker in logs/ — a hosted failure would be invisible'
}

printf '\033[1mTesting %s\033[0m\n' "$IMAGE"
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "Image not present locally; pulling…"; docker pull -q "$IMAGE" || exit 1; }

for s in "${SCENARIOS[@]}"; do
  case "$s" in
    plain) run_plain ;; volume) run_volume ;; codes) run_codes ;;
    hostname) run_hostname ;; nodb) run_nodb ;; freshdb) run_freshdb ;;
    *) echo "unknown scenario: $s" ;;
  esac
done

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$pass" "$failed"
[ "$failed" -eq 0 ]
