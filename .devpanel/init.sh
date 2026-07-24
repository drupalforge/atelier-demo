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

mkdir -p logs
LOG_FILE="logs/init-$(date +%F-%H%M%S).log"
exec > >(tee "$LOG_FILE") 2>&1
TIMEFORMAT=%lR
SECONDS=0

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

# --- Match config/sync to this container's database driver -------------------
# Drupal 11 ships database drivers as real modules, so core.extension.yml records
# whichever one the site was exported from. Atelier's config/sync comes off our
# Postgres stack and therefore lists `pgsql` — installing from it against DevPanel's
# MySQL makes config-import try to uninstall the module providing the ACTIVE driver,
# which core refuses outright:
#
#   The configuration synchronization failed validation.
#   Unable to uninstall the MySQL module because: The module 'MySQL' is providing
#   the database driver 'mysql'.
#
# The driver module is an artefact of where the config was exported, not a product
# decision, so rewrite it to the driver this container actually runs. config/sync is
# grafted into the image and committed to no repository, so this edits nothing a
# human maintains.
DB_MODULE="${DB_DRIVER:-mysql}"
CORE_EXTENSION='config/sync/core.extension.yml'
if ! grep -qE "^  ${DB_MODULE}: " "$CORE_EXTENSION"; then
  for other in pgsql mysql sqlite; do
    [ "$other" = "$DB_MODULE" ] && continue
    if grep -qE "^  ${other}: " "$CORE_EXTENSION"; then
      echo "Rewriting $CORE_EXTENSION: driver module ${other} → ${DB_MODULE}"
      sed -i -E "s/^  ${other}: ([0-9]+)$/  ${DB_MODULE}: \1/" "$CORE_EXTENSION"
    fi
  done
  if ! grep -qE "^  ${DB_MODULE}: " "$CORE_EXTENSION"; then
    echo "FATAL: could not record the ${DB_MODULE} driver module in $CORE_EXTENSION." >&2
    exit 1
  fi
fi

# --- Install Atelier --------------------------------------------------------
echo
if [ -z "$(drush status --field=db-status 2>/dev/null)" ]; then
  echo '== Install Atelier from config/sync =='
  # Install straight from the baked-in config/sync — config/sync IS the product's
  # desired state (it ships the branded aincient_theme as the front end). Applying
  # the recipe instead would leave an unbranded Olivero site. Mirrors
  # docker/converge.sh's fresh_install().
  #
  # A known admin/admin is intentional for a throwaway public demo: the visitor IS
  # the admin, and there is nothing here to protect. The appliance deliberately
  # does the opposite (mints a random password) — never copy this line into it.
  time drush -n site:install "${AINCIENT_INSTALL_PROFILE:-minimal}" --existing-config -y \
    --account-name=admin \
    --account-pass=admin \
    --site-name=Atelier

  # Right after install-from-config the extension registry is still stale, so a
  # follow-up pm:install cannot see what config just enabled and would try to
  # re-install it (PreExistingConfigException). Clear caches first.
  drush -n cache:rebuild

  # aincient_demo seeds the branded front door. It is deliberately NOT in
  # config/sync (one-shot showcase content), so install-from-config does not enable
  # it — do it explicitly, exactly as converge.sh does. Tolerate its absence so a
  # demo-less build still produces a usable image.
  echo
  echo '== Seed the branded homepage (aincient_demo) =='
  if ! drush -n pm:install aincient_demo -y; then
    echo 'WARN: demo seed skipped — the site will install with an unbranded front page.'
  fi
  drush -n cache:rebuild
else
  echo '== Existing database — run updates =='
  time drush -n updb -y
fi

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
