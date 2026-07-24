#!/usr/bin/env bash
#
# .devpanel/re-config.sh — Atelier demo, DEPLOY / RECONFIGURE.
#
# DevPanel runs this when the container's configuration is changed in the
# dashboard, or when the app is deployed to a hosting provider. It is part of the
# DevPanel script contract; an app whose repo omits it has nothing to run at that
# point in the lifecycle.
#
# Same work as init-container.sh minus the volume sync (the app root already lives
# in its volume by the time anything reconfigures it): make sure the database is
# there, re-assert the AI wiring for the current environment, warm up, fix
# ownership. Everything it calls is idempotent.
#
set -eu -o pipefail
export PATH="$APP_ROOT/vendor/bin:$PATH"
cd "$APP_ROOT"

# shellcheck source=lib.sh
. "$APP_ROOT/.devpanel/lib.sh"

dp_start_log re-config
dp_wait_for_db

# --- Writable state ---------------------------------------------------------
# A reconfigure can hand us fresh volumes, so do not assume these exist.
[ -d web/sites/default/files ] || mkdir -pm 775 web/sites/default/files
[ -d private ] || mkdir -m 775 private
[ -d config/sync ] || mkdir -pm 775 config/sync

# --- Database ---------------------------------------------------------------
dp_ensure_site

echo 'Apply any pending database updates.'
drush -n updb -y

# --- AI wiring --------------------------------------------------------------
# The environment is what just changed, so re-assert it: a new DP_AI_VIRTUAL_KEY or
# DP_AI_HOST takes effect here.
.devpanel/wire-ai.sh

# --- Warm up + ownership ----------------------------------------------------
echo 'Run cron.'
drush cron || :
echo 'Populate caches.'
drush cache:warm &> /dev/null || :
.devpanel/warm
.devpanel/warm /user/login

echo 'Fix ownership for strict permissions.'
sudo chown -R "${APACHE_RUN_USER:=www}" web/sites/default/files private config/sync
