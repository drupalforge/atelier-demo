#!/usr/bin/env bash
#
# .devpanel/doctor.sh — dump everything needed to diagnose a demo instance.
#
# Run it from the DevPanel terminal (or code-server) on a hosted instance when the
# app is not behaving and container logs are out of reach:
#
#   .devpanel/doctor.sh
#
# It never changes anything, always exits 0, and writes a copy to
# logs/doctor-<timestamp>.log so the output can be shared as a file.
#
# Each check prints OK / WARN / FAIL. Read the FAILs top-down: they are ordered so
# the first one is usually the cause.
#
set -u
export PATH="${APP_ROOT:-/var/www/html}/vendor/bin:$PATH"
APP_ROOT="${APP_ROOT:-/var/www/html}"
cd "$APP_ROOT" 2>/dev/null || { echo "FAIL: cannot cd to APP_ROOT=$APP_ROOT"; exit 0; }

mkdir -p logs 2>/dev/null || true
exec > >(tee "logs/doctor-$(date +%F-%H%M%S).log") 2>&1

ok()   { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; }
hdr()  { printf '\n\033[1m── %s\033[0m\n' "$*"; }

hdr 'Environment'
printf 'date          %s\n' "$(date -u +%FT%TZ)"
printf 'APP_ROOT      %s\n' "$APP_ROOT"
printf 'WEB_ROOT      %s\n' "${WEB_ROOT:-<unset>}"
printf 'DP_APP_ID     %s\n' "${DP_APP_ID:-<unset>}"
printf 'DP_HOSTNAME   %s\n' "${DP_HOSTNAME:-<unset>}"
printf 'DB_*          host=%s port=%s name=%s user=%s driver=%s\n' \
  "${DB_HOST:-<unset>}" "${DB_PORT:-<unset>}" "${DB_NAME:-<unset>}" \
  "${DB_USER:-<unset>}" "${DB_DRIVER:-<unset>}"
printf 'DP_AI_HOST    %s\n' "${DP_AI_HOST:-<unset>}"
# Never print the key itself — only whether it is there and how long it is.
if [ -n "${DP_AI_VIRTUAL_KEY:-}" ]; then
  printf 'DP_AI_VIRTUAL_KEY  set (%s chars)\n' "${#DP_AI_VIRTUAL_KEY}"
else
  printf 'DP_AI_VIRTUAL_KEY  <unset>  → the demo will show the onboarding wizard\n'
fi
printf 'php           %s\n' "$(php -r 'echo PHP_VERSION;' 2>&1)"

hdr 'Previous script runs (logs/)'
if ls logs/FAILED-*.log >/dev/null 2>&1; then
  for f in logs/FAILED-*.log; do
    fail "$f exists — a DevPanel script failed. Last 15 lines:"
    tail -15 "$f" | sed 's/^/        /'
  done
else
  ok 'no FAILED-*.log markers'
fi
ls -1t logs/*.log 2>/dev/null | head -8 | sed 's/^/      /' || echo '      (no logs yet)'

hdr 'Grafted Atelier tree'
for p in vendor/autoload.php web/core/lib/Drupal.php web/modules/custom/aincient_core \
         config/sync/core.extension.yml recipes web/sites/default/settings.php; do
  [ -e "$p" ] && ok "$p" || fail "$p MISSING"
done

hdr 'Database'
if [ "${DB_DRIVER:-mysql}" = mysql ] && command -v mysql >/dev/null 2>&1; then
  if mysql -h"${DB_HOST:-}" -P"${DB_PORT:-3306}" -u"${DB_USER:-}" -p"${DB_PASSWORD:-}" \
       -e 'select 1' "${DB_NAME:-}" >/dev/null 2>&1; then
    ok "connects to ${DB_HOST:-?}:${DB_PORT:-3306}/${DB_NAME:-?}"
    printf '      tables: %s\n' "$(mysql -N -B -h"${DB_HOST}" -P"${DB_PORT:-3306}" \
      -u"${DB_USER}" -p"${DB_PASSWORD}" -e \
      "select count(*) from information_schema.tables where table_schema='${DB_NAME}'" 2>/dev/null)"
  else
    fail "cannot connect to ${DB_HOST:-?}:${DB_PORT:-3306} as ${DB_USER:-?}"
  fi
fi
db_status="$(drush status --field=db-status 2>&1)"
if [ -n "$db_status" ] && [ "$db_status" = Connected ]; then
  ok "drush db-status: $db_status"
else
  fail "drush db-status: ${db_status:-<empty — Drupal sees no installed site>}"
  if [ -f .devpanel/dumps/db.sql.gz ]; then
    ok 'a baked dump is present (.devpanel/dumps/db.sql.gz) — init-container.sh can seed from it'
  else
    warn 'no .devpanel/dumps/db.sql.gz — normal after a volume sync, fatal if the database is also empty'
  fi
fi

hdr 'Drupal bootstrap'
boot="$(drush status --field=bootstrap 2>&1)"
[ -n "$boot" ] && ok "bootstrap: $boot" || fail "bootstrap failed: $(drush status 2>&1 | tail -5)"

hdr 'Image toolkit (every image style converts to AVIF)'
if command -v convert >/dev/null 2>&1; then
  if convert -list format 2>/dev/null | grep -qE '^ *AVIF .* rw'; then
    ok "$(convert -version | head -1)  (AVIF writable)"
  else
    fail 'ImageMagick cannot write AVIF — image derivatives will fail'
  fi
else
  fail 'no `convert` binary — the imagemagick toolkit cannot work'
fi

hdr 'AI wiring'
# Expected on a healthy demo: completed is EMPTY and roles are unbound — the
# visitor does onboarding themselves (wire-ai.sh only connects the provider). Both
# set means wire-ai.sh took its fallback path, or someone finished the wizard.
printf 'onboarding completed  %s\n' "$(drush state:get aincient_onboarding.completed 2>&1)"
drush config:get ai_provider_litellm.settings 2>&1 | sed 's/^/      /'
drush config:get key.key.litellm_api_key key_provider_settings 2>&1 | sed 's/^/      /'
drush config:get aincient_core.model_roles roles 2>&1 | sed 's/^/      /'
# The models step's pool, read the way the product reads it (GET /model/info via
# the provider plugin). Zero here means the wizard cannot offer anything, which is
# the one failure mode that would strand a visitor mid-onboarding.
printf 'chat models the wizard can offer  %s\n' "$(
  drush -n php:eval "
    try {
      \$m = \Drupal::service('aincient_onboarding.provider_connector')->modelsForStored('litellm');
      print count(\$m['chat']) . ' chat / ' . count(\$m['image']) . ' image';
    }
    catch (\Throwable \$e) {
      print 'ERROR — ' . \$e->getMessage();
    }
  " 2>&1 || true
)"

hdr 'HTTP (from inside the container, bypassing ingress)'
for path in / /user/login; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1${path}" 2>&1)"
  case "$code" in
    200|30*) ok "GET $path → $code" ;;
    400) fail "GET $path → 400 — trusted_host_patterns is rejecting this Host header. Probes will fail too." ;;
    *)   fail "GET $path → $code" ;;
  esac
done

hdr 'Recent PHP / Drupal errors'
drush watchdog:show --count=15 --severity=Error 2>/dev/null | sed 's/^/      /' \
  || warn 'could not read watchdog (dblog may be off or the site may not bootstrap)'

hdr 'Done'
echo "A copy of this report is in logs/ — attach it when asking for help."
exit 0
