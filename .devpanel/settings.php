<?php

/**
 * @file
 * Atelier on DevPanel — settings.php.
 *
 * .devpanel/Dockerfile copies this file over the settings.php that arrives with
 * the grafted appliance tree. The appliance version reads a single DATABASE_URL
 * and hardcodes /opt/drupal paths; under DevPanel the app root is /var/www/html
 * and the database arrives as DB_* environment variables.
 *
 * Everything real lives next door in settings.devpanel.php — this is only the
 * hand-off, so that the settings a demo container runs on are reviewable as a
 * normal file in this repo.
 */

$devpanel_settings = dirname($app_root) . '/.devpanel/settings.devpanel.php';
if (file_exists($devpanel_settings)) {
  include $devpanel_settings;
}
