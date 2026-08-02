# ---------------------------------------------------------------------------
# Atelier · Drupal Forge (DevPanel) demo — image build.
#
# This file is APPENDED to the Drupal Forge base Dockerfile by
# drupalforge/docker_publish_action, so it continues that same build stage: the
# base has already run `FROM ${BASE_IMAGE}`, copied this repo into $APP_ROOT
# (/var/www/html), chowned it to www:www and switched to USER www. The ARGs it
# declares (APP_ROOT, APACHE_RUN_USER, APACHE_RUN_GROUP) are still in scope here.
#
# Do NOT add a `# syntax=` directive — the action rejects the file if it finds one.
#
# What this adds on top of the base:
#   1. The ImageMagick CLI, with working AVIF + WebP encoders.
#   2. The Atelier product tree, GRAFTED out of the published atelier-cms image
#      instead of being resolved from Composer here — so the demo runs the exact
#      artifact we ship, and cannot drift from it.
#   3. A settings.php that hands over to .devpanel/settings.devpanel.php.
#   4. Timeout/docroot defaults the console needs.
#
# Full lifecycle (build → publish → container start): see .devpanel/README.md.
# ---------------------------------------------------------------------------

USER root

# --- 1. ImageMagick CLI -----------------------------------------------------
# config/sync pins `system.image` to the `imagemagick` toolkit, and every image
# style (thumbnail/medium/large/wide/media_library) runs image_convert_avif. The
# base image ships the imagick PHP *extension*, which that toolkit does not use —
# it shells out to `convert`. Without this the demo renders with broken images:
# every derivative silently fails to generate.
#
# Debian trixie's ImageMagick 7.1.1 reports `AVIF rw+` as soon as the libheif
# aomenc *encoder* plugin is installed. (The appliance image compiles ImageMagick
# from source only because Bookworm's package could not do this — on trixie the
# packaged build is enough.)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        imagemagick \
        libheif-plugin-aomenc \
    && rm -rf /var/lib/apt/lists/*

# --- 2. Graft the Atelier tree ----------------------------------------------
# /opt/drupal in the appliance image is the complete resolved project: composer
# manifests, vendor/, the scaffolded docroot with core + contrib + our custom
# modules and themes, recipes/, and the canonical config/sync. Copying it wholesale
# means no Composer resolution happens in this build at all.
#
# It lands ON TOP of this repo's checkout — which is why the demo repo carries no
# product code: only .devpanel/, the README and its assets sit alongside it.
#
# >>> THE LINE BELOW IS THE VERSION PIN. <<<
# Bumping this tag and pushing is how a new demo version gets promoted —
# deliberately decoupled from :edge on atelier-cms main. Always prefer an immutable
# tag (sha-<short>, or vX.Y.Z once we tag releases) over :edge or :latest.
#
# It has to be a literal: BuildKit rejects variable expansion in `COPY --from`
# ("variable expansion is not supported for --from"), and the ARG-plus-extra-stage
# workaround is not available to us — this file is appended AFTER the base
# Dockerfile's FROM, so there is no global scope left to declare an ARG in, and a
# trailing FROM would replace the base as the final image. One literal, one place to
# change. bin/build-local.sh rewrites it in a temporary copy when you pass
# ATELIER_IMAGE for a local build.
COPY --from=ghcr.io/aincient-labs/atelier-cms:sha-5ac2d72 /opt/drupal/ ${APP_ROOT}/

# --- 3. Settings ------------------------------------------------------------
# The appliance's settings.php reads a single DATABASE_URL and hardcodes
# /opt/drupal paths. DevPanel instead supplies DB_* and lives at /var/www/html, so
# swap in the stub that loads .devpanel/settings.devpanel.php.
RUN cp "${APP_ROOT}/.devpanel/settings.php" "${APP_ROOT}/web/sites/default/settings.php"

# --- 4. Apache / docroot ----------------------------------------------------
# The base template sets `Timeout 300`, but one console turn runs the FlowDrop
# agent loop inline in the request with a 540s wall-clock budget (PHP itself is
# given 600s via PHP_MAX_EXECUTION_TIME). At 300s Apache would sever a long page
# build mid-flight. Match the appliance, which pins 600s for exactly this reason.
# apache-start.sh re-copies /templates/apache2.conf on every container start, so
# the template is the file that has to change — editing /etc/apache2 would be
# overwritten.
RUN sed -i 's/^Timeout .*/Timeout 600/' /templates/apache2.conf \
    && grep -q '^Timeout 600' /templates/apache2.conf

# Safety net: the vhost template renders DocumentRoot from $WEB_ROOT, and the base
# image defaults it to $APP_ROOT (no /web). DevPanel and the publish action both
# pass the correct value, but defaulting it here means a container started without
# it still serves the docroot rather than the project root.
ENV WEB_ROOT=${APP_ROOT}/web

# --- 5. Writable state ------------------------------------------------------
RUN mkdir -p \
        "${APP_ROOT}/web/sites/default/files" \
        "${APP_ROOT}/private/snapshots" \
        "${APP_ROOT}/config/sync" \
        "${APP_ROOT}/logs" \
        "${APP_ROOT}/.devpanel/dumps" \
    && chown -R "${APACHE_RUN_USER}":"${APACHE_RUN_GROUP}" "${APP_ROOT}" \
    && chmod 775 "${APP_ROOT}/web/sites/default"

USER ${USER}
