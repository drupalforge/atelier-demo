#!/usr/bin/env bash
#
# .devpanel/init-container.sh — Atelier demo, CONTAINER START (registry mode).
#
# DevPanel runs this every time a container comes up from the published demo
# image. "Registry mode" means the image already contains an installed site, so
# nothing here installs Drupal. The work is:
#
#   1. import the database dump baked in by create_quickstart.sh,
#   2. re-assert the AI wiring, so each container uses ITS OWN injected trial key,
#   3. sync the image's app root out to the external volume (DB_SYNC_VOL),
#   4. run cron, warm caches, fix ownership.
#
# init.sh is the image-BUILD counterpart and does not run here.
#
set -eu -o pipefail
export PATH="$APP_ROOT/vendor/bin:$PATH"
cd "$APP_ROOT"

# --- 1. Import the baked database -------------------------------------------
if [ -z "$(drush status --field=db-status 2>/dev/null)" ]; then
  if [ -f .devpanel/dumps/db.sql.gz ]; then
    echo 'Import the baked database.'
    # Paths are resolved relative to the Drupal root (web/), hence the ../.
    drush sqlq --file=../.devpanel/dumps/db.sql.gz
    # drush gunzips the dump in place; re-compress so the next container built off
    # this volume still finds db.sql.gz.
    gzip -f .devpanel/dumps/db.sql 2>/dev/null || :
    echo 'Apply any pending database updates.'
    drush -n updb -y
  else
    echo 'WARN: no .devpanel/dumps/db.sql.gz and no database — this container has no site.' >&2
  fi
fi

# --- 2. Per-container AI wiring ---------------------------------------------
# The key entity is an ENV provider, so the secret itself was never baked into the
# dump — but re-running this is what makes a container work when the image was
# built WITHOUT a trial key and this container has one (and it is a no-op
# otherwise).
.devpanel/wire-ai.sh

# --- 3. Sync the app root to the external volume ----------------------------
# DevPanel starts the image with an empty volume mounted at ../build, copies the
# app root into it, then re-runs with that volume mounted AT the app root so edits
# persist. The marker file tells us the copy has already happened.
if [ -n "${DB_SYNC_VOL:-}" ]; then
  if [ ! -f "../build/.devpanel/init-container.sh" ]; then
    echo 'Sync volume...'
    if [ -n "${DRUPALFORGE_DEVCONTAINER:-}" ]; then
      # Preserve source permissions, but keep rsync-created directories writable so
      # it can carry on copying nested files into a fresh volume.
      sudo rsync -a --chmod=Du+w --ignore-existing \
        --exclude .git --exclude .devpanel/dumps ./ ../build
    else
      sudo rsync -av --delete --delete-excluded \
        --exclude .devpanel/dumps ./ ../build
    fi
  fi
fi

# --- 4. Warm up + ownership -------------------------------------------------
echo 'Run cron.'
drush cron || :
echo 'Populate caches.'
drush cache:warm &> /dev/null || :
.devpanel/warm
.devpanel/warm /user/login

echo 'Fix ownership for strict permissions.'
sudo chown -R "${APACHE_RUN_USER:=www}" web/sites/default/files private config/sync
