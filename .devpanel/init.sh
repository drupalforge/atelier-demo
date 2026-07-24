#!/usr/bin/env bash
#
# .devpanel/init.sh — Atelier · Drupal Forge (DevPanel) demo.
#
# DevPanel runs this AFTER the prebuilt Atelier image
# (ghcr.io/aincient-labs/atelier-cms) has started from the registry. The image's
# own entrypoint (converge → Apache) has already installed the site from the
# baked-in config/sync, so this script's ONLY job is to layer the DevPanel-managed
# LiteLLM trial key on top and skip the first-run onboarding wizard — nothing here
# installs Drupal.
#
# Why this lives here and not in the product image: the product boots keyless by
# design (DECISIONS 0149 — onboarding is the sole key path). The trial-key seed is
# DevPanel-specific, so it stays entirely in the demo layer. See
# aincient-workspace/plans/forge-demo.md.
#
# Env (injected by DevPanel):
#   DP_AI_VIRTUAL_KEY  the $1 LiteLLM trial key (required; no key ⇒ keyless demo)
#   DP_AI_HOST         LiteLLM proxy base URL (default https://ai.drupalforge.org)
#
set -euo pipefail

DRUPAL_ROOT="${DRUPAL_ROOT:-/opt/drupal}"
DRUSH="${DRUSH:-$DRUPAL_ROOT/vendor/bin/drush}"
DP_AI_HOST="${DP_AI_HOST:-https://ai.drupalforge.org}"

# Budget model: cheapest capable Claude everywhere so the $1 trial stretches to
# ~"3 pages + 1 brand". Image generation is intentionally left UNBOUND — no image
# model on the proxy, and an unbound image role cleanly hides the AI-image
# affordances rather than erroring (aincient_core roles.image gate).
DEMO_MODEL="anthropic/claude-haiku-4-5"

cd "$DRUPAL_ROOT"

if [ -z "${DP_AI_VIRTUAL_KEY:-}" ]; then
  echo "init.sh: DP_AI_VIRTUAL_KEY is unset — leaving the demo keyless (onboarding wizard will show)."
  exit 0
fi

# Guard against a race with the image's converge step (usually already done, since
# converge runs before Apache in the entrypoint, but be defensive on restarts).
echo "init.sh: waiting for Drupal bootstrap…"
for _ in $(seq 1 30); do
  if $DRUSH status --field=bootstrap 2>/dev/null | grep -qi "Successful"; then
    break
  fi
  sleep 2
done

echo "init.sh: enabling ai_provider_litellm…"
$DRUSH -y pm:install ai_provider_litellm

# Store the trial key as an ENV-provider Key entity: the secret is read live from
# the container env on each request and is never written to config, State, or the
# database. (base64_encoded:false, strip_line_breaks:true per the DevPanel pattern.)
echo "init.sh: wiring the LiteLLM key + host…"
$DRUSH -y key:save litellm_api_key \
  --label="LiteLLM trial key (DevPanel)" \
  --key-type=authentication \
  --key-provider=env \
  --key-input=none \
  --key-provider-settings='{"env_variable":"DP_AI_VIRTUAL_KEY","base64_encoded":false,"strip_line_breaks":true}'

$DRUSH -y config:set ai_provider_litellm.settings api_key    litellm_api_key
$DRUSH -y config:set ai_provider_litellm.settings host       "$DP_AI_HOST"
$DRUSH -y config:set ai_provider_litellm.settings moderation false --input-format=yaml

# Bind all three model roles to the budget model and project the bindings onto
# ai.settings + flowdrop_chat (the exact API the onboarding wizard uses). The
# `image` role is deliberately never bound.
echo "init.sh: binding model roles to $DEMO_MODEL…"
$DRUSH php:eval '
  $r = \Drupal::service("aincient_core.model_role_resolver");
  foreach (["reasoning", "task", "fast"] as $role) {
    $r->bind($role, "litellm", "'"$DEMO_MODEL"'");
  }
  $r->project();
'

# A provider is now configured, so the wizard would be skipped anyway; set the
# completion flag explicitly so demo visitors land straight in the console.
$DRUSH state:set aincient_onboarding.completed 1

$DRUSH cache:rebuild

echo "init.sh: done — LiteLLM trial key wired, roles → $DEMO_MODEL, onboarding skipped, image gen off."
