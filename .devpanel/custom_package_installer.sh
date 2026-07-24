#!/usr/bin/env bash
#
# .devpanel/custom_package_installer.sh — runs as ROOT on every container start,
# from /scripts/apache-start.sh, before Apache comes up.
#
# Two jobs:
#   1. cheap local hardening + an ImageMagick sanity check,
#   2. a LAST-RESORT seed of the site, because this is the only hook the base image
#      runs unconditionally, whichever mode the DevPanel app is configured in.
#
# No package installation: everything the demo needs (the ImageMagick CLI with AVIF
# and WebP encoders) is baked into the image by .devpanel/Dockerfile, so container
# start stays fast and needs no network.
#
# Output lands in /tmp/custom_package_installer.log (apache-start.sh redirects it),
# and the seed step also logs into $APP_ROOT/logs/ where we can actually read it.
#
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi

APP_ROOT="${APP_ROOT:-/var/www/html}"

# Xdebug would add per-request overhead to a public demo (and the AI console makes
# long requests). Drop it if the base image ever ships it enabled.
if [ -f /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini ]; then
  echo 'Disabling Xdebug.'
  rm -f /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini
fi

# Sanity check, not a fix: config/sync pins the imagemagick toolkit and every image
# style converts to AVIF. init.sh already fails the BUILD if this is wrong, so a
# warning here would mean the image was assembled some other way.
if command -v convert >/dev/null 2>&1; then
  if convert -list format 2>/dev/null | grep -qE '^ *AVIF .* rw'; then
    echo "ImageMagick OK (AVIF writable): $(convert -version | head -1)"
  else
    echo 'WARNING: ImageMagick cannot write AVIF — image styles will fail.' >&2
  fi
else
  echo 'WARNING: no `convert` binary — the imagemagick image toolkit cannot work.' >&2
fi

# --- Last-resort seed -------------------------------------------------------
# If Drupal is not installed by the time Apache starts, the public gets
# /core/install.php: a broken demo, and a hole — a visitor could complete the
# install with their own admin account. That is exactly what happened on the first
# hosted instance, because DevPanel's app-root volume sync drops
# .devpanel/dumps and the container it serves came up with an empty database.
#
# Every other path (init-container.sh, re-config.sh) already guarantees a site, but
# they only run if DevPanel is configured to call them. THIS script always runs, so
# it is the backstop.
#
# Gated on the immutable seed existing, which is only true after create_quickstart.sh
# has run — so this is inert during the image build, where init.sh owns the install.
DP_SEED_FILE="${DP_SEED_FILE:-/opt/atelier-seed/db.sql.gz}"
if [ -f "$DP_SEED_FILE" ] && [ -f "$APP_ROOT/.devpanel/lib.sh" ]; then
  # Run as the web user, never as root: drush as root would leave root-owned files
  # in sites/default/files that Apache then cannot write.
  #
  # `sudo -E` and not `runuser`: runuser resets the environment, so the child would
  # lose APP_ROOT and every DB_* variable and fail to reach the database. This is
  # also the form apache-start.sh itself uses when it needs the environment.
  WEB_USER="${APACHE_RUN_USER:-www}"
  if ! sudo -u "$WEB_USER" -E -- bash -c \
      'export PATH="$APP_ROOT/vendor/bin:$PATH"; cd "$APP_ROOT" && [ -n "$(drush status --field=db-status 2>/dev/null)" ]' \
      2>/dev/null; then
    echo 'No installed site found at container start — seeding before Apache.'
    # Best effort: this must never prevent Apache from starting. A failure here
    # leaves logs/FAILED-startup-seed.log behind for diagnosis.
    sudo -u "$WEB_USER" -E -- bash -c '
      set -eu -o pipefail
      export PATH="$APP_ROOT/vendor/bin:$PATH"
      cd "$APP_ROOT"
      . "$APP_ROOT/.devpanel/lib.sh"
      dp_start_log startup-seed
      dp_wait_for_db 45
      dp_ensure_site
      "$APP_ROOT"/.devpanel/wire-ai.sh
      drush cache:rebuild
    ' || echo 'WARNING: the startup seed failed — see $APP_ROOT/logs/FAILED-startup-seed.log' >&2
    chown -R "${APACHE_RUN_USER:-www}" \
      "$APP_ROOT/web/sites/default/files" "$APP_ROOT/private" "$APP_ROOT/config/sync" 2>/dev/null || true
  else
    echo 'Site already installed.'
  fi
fi
