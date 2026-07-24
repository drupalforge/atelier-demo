#!/usr/bin/env bash
#
# .devpanel/create_quickstart.sh — bake the installed site into the demo image.
#
# drupalforge/docker_publish_action runs this straight after init.sh, then commits
# the container as the published image. The database dump it writes here is what
# init-container.sh imports on every container start.
#
# Static files are NOT shipped this way: the action deletes files.tgz right after
# calling us, because the committed container filesystem already contains
# web/sites/default/files. The tarball is still produced so a local build (or a
# hosting handoff via re-config.sh) has one available.
#
set -eu -o pipefail
export PATH="$APP_ROOT/vendor/bin:$PATH"
cd "$APP_ROOT"

# shellcheck source=lib.sh
. "$APP_ROOT/.devpanel/lib.sh"

mkdir -p .devpanel/dumps
drush cr

echo "> Export the database to $APP_ROOT/.devpanel/dumps"
# Paths are resolved relative to the Drupal root (web/), hence the ../.
drush sql-dump --result-file=../.devpanel/dumps/db.sql --gzip

# Keep a second copy OUTSIDE the app root.
#
# DevPanel copies the app root into a volume and mounts it back over the app root,
# and that sync excludes .devpanel/dumps — so the copy above is gone by the time the
# served container starts. If the served container also gets an empty database, the
# site never gets seeded and the public sees /core/install.php. This copy lives in
# the image, where the volume cannot shadow it, and is what dp_ensure_site() reads.
echo "> Stash an immutable copy at $DP_SEED_FILE"
sudo mkdir -p "$(dirname "$DP_SEED_FILE")"
sudo cp .devpanel/dumps/db.sql.gz "$DP_SEED_FILE"
sudo chmod 0444 "$DP_SEED_FILE"
ls -lh "$DP_SEED_FILE"

echo '> Compress static files'
tar czf .devpanel/dumps/files.tgz -C "${WEB_ROOT:-$APP_ROOT/web}/sites/default/files" .

ls -lh .devpanel/dumps
