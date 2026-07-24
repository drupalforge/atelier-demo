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

mkdir -p .devpanel/dumps
drush cr

echo "> Export the database to $APP_ROOT/.devpanel/dumps"
# Paths are resolved relative to the Drupal root (web/), hence the ../.
drush sql-dump --result-file=../.devpanel/dumps/db.sql --gzip

echo '> Compress static files'
tar czf .devpanel/dumps/files.tgz -C "${WEB_ROOT:-$APP_ROOT/web}/sites/default/files" .

ls -lh .devpanel/dumps
