#!/usr/bin/env bash
#
# .devpanel/custom_package_installer.sh — runs as ROOT on every container start,
# from /scripts/apache-start.sh, before Apache comes up.
#
# Deliberately does no package installation: everything the demo needs (the
# ImageMagick CLI with AVIF/WebP encoders) is baked into the image by
# .devpanel/Dockerfile, so container start stays fast and needs no network.
#
# What is left is cheap, local hardening + a sanity check whose output lands in
# /tmp/custom_package_installer.log.
#
if [ -n "${DEBUG_SCRIPT:-}" ]; then
  set -x
fi

# Xdebug would add per-request overhead to a public demo (and the AI console makes
# long requests). Drop it if the base image ever ships it enabled.
if [ -f /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini ]; then
  echo 'Disabling Xdebug.'
  rm -f /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini
fi

# Sanity check, not a fix: config/sync pins the imagemagick toolkit and every image
# style converts to AVIF. init.sh already fails the BUILD if this is wrong, so a
# warning here would only mean the image was assembled some other way.
if command -v convert >/dev/null 2>&1; then
  if convert -list format 2>/dev/null | grep -qE '^ *AVIF .* rw'; then
    echo "ImageMagick OK (AVIF writable): $(convert -version | head -1)"
  else
    echo 'WARNING: ImageMagick cannot write AVIF — image styles will fail.' >&2
  fi
else
  echo 'WARNING: no `convert` binary — the imagemagick image toolkit cannot work.' >&2
fi
