#!/usr/bin/env bash
#
# .devpanel/init.sh — Atelier · Drupal Forge (DevPanel) demo, IMAGE BUILD step.
#
# Run ONCE, by drupalforge/docker_publish_action, inside the freshly built image
# with a MySQL service attached (and by bin/build-local.sh, which reproduces that
# locally). It installs Atelier from the grafted config/sync so the published demo
# image already contains a working site; create_quickstart.sh then bakes the
# resulting database into the image.
#
# It does NOT resolve Composer. .devpanel/Dockerfile grafts the entire resolved
# tree — vendor/, core, contrib, our custom modules and themes, recipes/,
# config/sync — straight out of the published atelier-cms image, so there is
# nothing left to install and no way for the demo to drift from what we ship.
#
# At container START it is init-container.sh that runs, not this file.
#
# Env (supplied by the action / DevPanel): APP_ROOT, WEB_ROOT, DB_*,
#   APACHE_RUN_USER, DP_AI_VIRTUAL_KEY, DP_AI_HOST.
#
export PATH="$APP_ROOT/vendor/bin:$PATH"
if [ -n "${DEBUG_SCRIPT:-}" ]; then set -x; fi
set -eu -o pipefail
cd "$APP_ROOT"

# shellcheck source=lib.sh
. "$APP_ROOT/.devpanel/lib.sh"

dp_start_log init
TIMEFORMAT=%lR
SECONDS=0

# The publish action starts MySQL alongside the container without waiting for it,
# so the install can otherwise race the database coming up.
dp_wait_for_db

# --- Verify the graft -------------------------------------------------------
# Everything below assumes .devpanel/Dockerfile put the product tree in place. If
# it did not, fail the BUILD loudly here rather than publishing an image that only
# breaks once a visitor opens it.
echo
echo '== Verify the grafted Atelier tree =='
for path in \
    vendor/autoload.php \
    web/core/lib/Drupal.php \
    web/modules/custom/aincient_core \
    config/sync/core.extension.yml \
    recipes; do
  if [ ! -e "$path" ]; then
    echo "FATAL: $path is missing — the .devpanel/Dockerfile graft did not run." >&2
    exit 1
  fi
done
echo "grafted tree looks complete"

# config/sync pins the imagemagick toolkit and every image style converts to AVIF,
# so a container without an AVIF-capable `convert` renders broken images site-wide.
# Assert it here, at build time, where it is cheap to notice.
if grep -q '^toolkit: imagemagick' config/sync/system.image.yml; then
  if ! command -v convert >/dev/null 2>&1; then
    echo 'FATAL: config/sync pins the imagemagick toolkit but no `convert` binary is installed.' >&2
    exit 1
  fi
  if ! convert -list format | grep -qE '^ *AVIF .* rw'; then
    echo 'FATAL: ImageMagick cannot WRITE AVIF — every image style would fail.' >&2
    echo '       Install libheif-plugin-aomenc (see .devpanel/Dockerfile).' >&2
    convert -list format | grep -iE 'avif|heic' >&2 || true
    exit 1
  fi
  echo "ImageMagick can write AVIF: $(convert -version | head -1)"
fi

# --- Writable state ---------------------------------------------------------
[ -d private ] || mkdir -m 775 private
[ -d config/sync ] || mkdir -pm 775 config/sync
sudo chmod 775 -R private config web/sites/default/files 2>/dev/null || true

# --- Install Atelier --------------------------------------------------------
# dp_ensure_site() installs from config/sync (no seed exists yet at build time),
# aligns config/sync's database driver module to this container's driver, and seeds
# the branded homepage. It fails loudly rather than leaving a site-less image.
echo
echo '== Install Atelier from config/sync =='
time dp_ensure_site

# --- AI wiring --------------------------------------------------------------
echo
echo '== Wire the LiteLLM trial key =='
.devpanel/wire-ai.sh

# --- Warm up ----------------------------------------------------------------
echo
echo '== Run cron =='
time drush cron || :
echo
echo '== Populate caches =='
time drush cache:warm &> /dev/null || :
time .devpanel/warm
time .devpanel/warm /user/login

# --- Ownership --------------------------------------------------------------
# drush ran as the web user here, but site:install and cache:rebuild create nested
# directories (styles/, css/, js/, php/) whose modes matter once Apache serves
# requests. Re-assert them before the image is committed.
echo
echo '== Fix ownership for strict permissions =='
sudo chmod 775 -R web/sites/default/files
sudo chown -R "${APACHE_RUN_USER:=www}" web/sites/default/files private config/sync

printf "\nTotal elapsed time: %d:%02d:%02d\n" $((SECONDS / 3600)) $((SECONDS % 3600 / 60)) $((SECONDS % 60))
