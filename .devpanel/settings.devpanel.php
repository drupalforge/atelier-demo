<?php

/**
 * @file
 * Atelier on DevPanel — the real settings.
 *
 * Included from web/sites/default/settings.php (see .devpanel/settings.php).
 * DevPanel supplies MySQL as DB_* environment variables and the app root as
 * /var/www/html, so this replaces the appliance's DATABASE_URL wiring.
 */

use Symfony\Component\HttpFoundation\Request;

// --- Database ---------------------------------------------------------------
// DevPanel provides MySQL 8. Postgres is Atelier's shipped default, not a
// requirement — nothing in the product is Postgres-specific.
$databases['default']['default'] = [
  'driver' => getenv('DB_DRIVER') ?: 'mysql',
  'database' => getenv('DB_NAME'),
  'username' => getenv('DB_USER'),
  'password' => getenv('DB_PASSWORD'),
  'host' => getenv('DB_HOST'),
  'port' => getenv('DB_PORT'),
  'prefix' => '',
  'isolation_level' => 'READ COMMITTED',
];
$driver = $databases['default']['default']['driver'];
$databases['default']['default']['namespace'] = "Drupal\\{$driver}\\Driver\\Database\\{$driver}";
$databases['default']['default']['autoload'] = "core/modules/{$driver}/src/Driver/Database/{$driver}/";
if ($driver === 'mysql') {
  $databases['default']['default']['collation'] = 'utf8mb4_general_ci';
}

// --- Paths + salt -----------------------------------------------------------
if (empty($settings['hash_salt'])) {
  $settings['hash_salt'] = hash('sha256', serialize($databases));
}
$settings['config_sync_directory'] = '../config/sync';
$settings['file_private_path'] = $app_root . '/../private';
$realpath = realpath($settings['file_private_path']);
if (!empty($realpath)) {
  $settings['file_private_path'] = $realpath;
}
$settings['update_free_access'] = FALSE;

// --- Keep the demo homepage across config imports ---------------------------
// aincient_demo seeds the branded showcase homepage and is deliberately kept OUT
// of config/sync (it is one-shot content, enabled explicitly by init.sh, exactly
// as docker/converge.sh does on the appliance). Without this exclusion any
// config:import would uninstall it purely because core.extension.yml omits it —
// stripping the demo's front page. Mirrors settings.appliance.php.
$settings['config_exclude_modules'] = ['aincient_demo'];

// --- Hosts ------------------------------------------------------------------
if (getenv('DP_HOSTNAME')) {
  $settings['trusted_host_patterns'][] = '^' . preg_quote(getenv('DP_HOSTNAME'), '/') . '$';
}
else {
  $settings['trusted_host_patterns'][] = '.*';
}

// --- Dev container ----------------------------------------------------------
// VS Code fronts the container with a port-forwarding proxy; trust its headers so
// Drupal generates correct absolute URLs.
if (getenv('DRUPALFORGE_DEVCONTAINER') && isset($_SERVER['HTTP_X_FORWARDED_HOST'], $_SERVER['REMOTE_ADDR'])) {
  $settings['reverse_proxy'] = TRUE;
  $settings['reverse_proxy_addresses'] = [$_SERVER['REMOTE_ADDR']];
  $settings['reverse_proxy_trusted_headers'] =
    Request::HEADER_X_FORWARDED_HOST |
    Request::HEADER_X_FORWARDED_PROTO |
    Request::HEADER_X_FORWARDED_PORT;
}
