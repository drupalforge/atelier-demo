#!/usr/bin/env bash
#
# .devpanel/lib.sh — shared helpers for the DevPanel scripts.
#
# Sourced (not executed) by init.sh, init-container.sh, re-config.sh and
# custom_package_installer.sh.
#
# Two problems this file exists to solve, both learned the hard way on a hosted
# instance:
#
#   1. We cannot read container stdout — that goes to Kubernetes. So every script
#      mirrors its output into $APP_ROOT/logs/ (reachable through DevPanel's
#      terminal, code-server, or the app-root volume) and drops a loud marker file
#      when it fails. A broken deploy must always leave evidence we can reach.
#
#   2. The site must exist by the time Apache serves a request. If it does not,
#      Drupal falls through to /core/install.php and the demo shows a bare install
#      wizard to the public — which is both broken and a hole (a visitor could
#      complete the install with their own admin account). dp_ensure_site() makes
#      that outcome impossible: it tries the immutable seed, then the in-tree dump,
#      then a full install from config/sync, and fails loudly if all three fail.

# The database seed, baked at image build time OUTSIDE the app root.
#
# This location matters. DevPanel copies the app root into a volume and then mounts
# that volume back over the app root, and the sync deliberately excludes
# .devpanel/dumps — so anything kept only in the app root is GONE by the time the
# served container starts. /opt is part of the image and can never be shadowed by
# the volume, so this copy always survives.
DP_SEED_FILE="${DP_SEED_FILE:-/opt/atelier-seed/db.sql.gz}"

# --- Logging ---------------------------------------------------------------

dp_start_log() {
  local name="$1"
  mkdir -p "$APP_ROOT/logs" 2>/dev/null || true
  DP_LOG_FILE="$APP_ROOT/logs/${name}-$(date +%F-%H%M%S).log"
  DP_SCRIPT_NAME="$name"
  exec > >(tee -a "$DP_LOG_FILE") 2>&1
  echo "[$name] $(date -u +%FT%TZ) starting (log: $DP_LOG_FILE)"
  trap 'dp_report_exit $?' EXIT
}

dp_report_exit() {
  local code="${1:-0}"
  if [ "$code" -eq 0 ]; then
    echo "[${DP_SCRIPT_NAME}] $(date -u +%FT%TZ) completed OK"
    rm -f "$APP_ROOT/logs/FAILED-${DP_SCRIPT_NAME}.log" 2>/dev/null || true
  else
    echo "[${DP_SCRIPT_NAME}] $(date -u +%FT%TZ) FAILED with exit code ${code}"
    # A copy under a fixed, loud name: whoever opens logs/ sees it immediately.
    cp -f "$DP_LOG_FILE" "$APP_ROOT/logs/FAILED-${DP_SCRIPT_NAME}.log" 2>/dev/null || true
  fi
}

# --- Database --------------------------------------------------------------

# Wait for the database to actually accept connections.
#
# DevPanel starts the database alongside the app, so a container can run its init
# script before the server is listening. Without this the first thing we do dies on
# "Unknown server host" / "Connection refused", `set -e` aborts, and the instance is
# left half-initialised — the failure that is impossible to diagnose without logs.
dp_wait_for_db() {
  local tries="${1:-60}" i
  if [ "${DB_DRIVER:-mysql}" != mysql ]; then
    echo "dp_wait_for_db: DB_DRIVER=${DB_DRIVER} is not mysql — skipping the wait."
    return 0
  fi
  printf 'Waiting for %s:%s to accept connections' "${DB_HOST:-?}" "${DB_PORT:-3306}"
  for i in $(seq 1 "$tries"); do
    if mysql -h"${DB_HOST}" -P"${DB_PORT:-3306}" -u"${DB_USER}" \
         -p"${DB_PASSWORD}" -e 'select 1' "${DB_NAME}" >/dev/null 2>&1; then
      echo ' ready.'
      return 0
    fi
    printf '.'
    sleep 2
  done
  echo
  echo "FATAL: the database at ${DB_HOST}:${DB_PORT:-3306} never accepted connections." >&2
  echo "       DB_NAME=${DB_NAME} DB_USER=${DB_USER} DB_DRIVER=${DB_DRIVER:-mysql}" >&2
  return 1
}

dp_site_installed() {
  [ -n "$(drush status --field=db-status 2>/dev/null)" ]
}

# --- Config ----------------------------------------------------------------

# Point config/sync's database driver module at the driver this container runs.
#
# Drupal 11 ships database drivers as real modules, so core.extension.yml records
# whichever one the site was exported from. Atelier's config/sync comes off our
# Postgres stack and lists `pgsql`; installing from it on MySQL makes config-import
# try to uninstall the module providing the ACTIVE driver, which core refuses:
#
#   Unable to uninstall the MySQL module because: The module 'MySQL' is providing
#   the database driver 'mysql'.
dp_align_driver_module() {
  local want="${DB_DRIVER:-mysql}" other
  local file='config/sync/core.extension.yml'
  [ -f "$file" ] || return 0
  grep -qE "^  ${want}: " "$file" && return 0
  for other in pgsql mysql sqlite; do
    [ "$other" = "$want" ] && continue
    if grep -qE "^  ${other}: " "$file"; then
      echo "Rewriting $file: driver module ${other} → ${want}"
      sed -i -E "s/^  ${other}: ([0-9]+)$/  ${want}: \1/" "$file"
    fi
  done
  if ! grep -qE "^  ${want}: " "$file"; then
    echo "FATAL: could not record the ${want} driver module in $file." >&2
    return 1
  fi
}

# --- Seeding ---------------------------------------------------------------

dp_import_dump() {
  local dump="$1"
  echo "Importing the database from ${dump}"
  # Piped through sql:cli rather than `sqlq --file=`, which gunzips the dump in
  # place — the seed under /opt must stay intact for the next container.
  zcat "$dump" | drush sql:cli
  drush -n updb -y
}

dp_install_from_config() {
  echo 'Installing Atelier from config/sync'
  dp_align_driver_module
  # Install straight from config/sync — that IS the product's desired state (it
  # ships the branded aincient_theme as the front end). Applying the recipe instead
  # would leave an unbranded Olivero site.
  #
  # A known admin/admin is intentional for a throwaway public demo: the visitor IS
  # the admin and there is nothing here to protect. The appliance deliberately does
  # the opposite (mints a random password) — never copy this into it.
  drush -n site:install "${AINCIENT_INSTALL_PROFILE:-minimal}" --existing-config -y \
    --account-name=admin \
    --account-pass=admin \
    --site-name=Atelier
  # Right after install-from-config the extension registry is stale, so a follow-up
  # pm:install cannot see what config just enabled and would try to re-install it.
  drush -n cache:rebuild
  # aincient_demo seeds the branded front door and is deliberately NOT in
  # config/sync (one-shot showcase content), so enable it explicitly — exactly as
  # docker/converge.sh does on the appliance.
  if ! drush -n pm:install aincient_demo -y; then
    echo 'WARN: demo seed skipped — the site will have an unbranded front page.'
  fi
  drush -n cache:rebuild
}

# Guarantee an installed site, or fail loudly. Never returns 0 with no site.
dp_ensure_site() {
  if dp_site_installed; then
    echo 'Site is already installed.'
    return 0
  fi

  if [ -f "$DP_SEED_FILE" ]; then
    dp_import_dump "$DP_SEED_FILE"
  elif [ -f .devpanel/dumps/db.sql.gz ]; then
    # Present in the image, but excluded from the app-root volume sync — so this
    # branch only fires before the volume takes over.
    dp_import_dump .devpanel/dumps/db.sql.gz
  elif [ -f config/sync/core.extension.yml ]; then
    # No seed anywhere. The grafted tree still has vendor/ and config/sync, so a
    # full install is always possible — slower (~30s) but it cannot leave the
    # public looking at /core/install.php.
    echo 'No database seed found — falling back to a full install from config/sync.'
    dp_install_from_config
  else
    echo 'FATAL: no database, no seed, and no config/sync to install from.' >&2
    return 1
  fi

  if ! dp_site_installed; then
    echo 'FATAL: seeding ran but Drupal still reports no installed site.' >&2
    return 1
  fi
  echo 'Site is installed.'
}
