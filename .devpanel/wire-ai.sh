#!/usr/bin/env bash
#
# .devpanel/wire-ai.sh — hand the demo its DevPanel-managed LiteLLM trial key.
#
# Called by init.sh (image build) and again by init-container.sh (every container
# start), so it must be idempotent — and it is: each step is either a no-op when
# already applied or safe to re-apply.
#
# Why this lives in the demo layer and nowhere near the product: Atelier boots
# keyless by design, with the onboarding wizard as the only key path (DECISIONS
# 0149). A pre-seeded trial key is a DevPanel concept, so it is injected here and
# only here — a self-hosted install is untouched.
#
# Env:
#   DP_AI_VIRTUAL_KEY  the trial key (unset ⇒ nothing happens, demo stays keyless)
#   DP_AI_HOST         LiteLLM proxy base URL (default https://ai.drupalforge.org)
#   DEMO_MODEL         override the budget model
#
set -eu -o pipefail
cd "${APP_ROOT:?APP_ROOT must be set}"
export PATH="$APP_ROOT/vendor/bin:$PATH"

# Budget model: the cheapest capable Claude everywhere, so a $1 trial stretches to
# roughly "3 pages + 1 brand". Our flows and prompts are tuned for Claude.
DEMO_MODEL="${DEMO_MODEL:-anthropic/claude-haiku-4-5}"
DP_AI_HOST="${DP_AI_HOST:-https://ai.drupalforge.org}"

if [ -z "${DP_AI_VIRTUAL_KEY:-}" ]; then
  echo "wire-ai: DP_AI_VIRTUAL_KEY is unset — leaving the demo keyless (the onboarding wizard will show)."
  exit 0
fi

echo "wire-ai: enabling ai_provider_litellm"
drush -n pm:install ai_provider_litellm -y

# Store the key as an ENV-provider Key entity: the secret is read live out of the
# container environment on every request, so it is never written to config, State
# or the database — and therefore never ends up inside the image's database dump.
# Each demo container consequently uses its own injected key.
if drush -n config:get key.key.litellm_api_key id >/dev/null 2>&1; then
  echo "wire-ai: key entity litellm_api_key already present"
else
  echo "wire-ai: creating the litellm_api_key entity (env provider)"
  drush -n key:save litellm_api_key \
    --label="LiteLLM trial key (DevPanel)" \
    --key-type=authentication \
    --key-provider=env \
    --key-input=none \
    --key-provider-settings='{"env_variable":"DP_AI_VIRTUAL_KEY","base64_encoded":false,"strip_line_breaks":true}'
fi

echo "wire-ai: pointing ai_provider_litellm at $DP_AI_HOST"
drush -n config:set ai_provider_litellm.settings api_key litellm_api_key -y
drush -n config:set ai_provider_litellm.settings host "$DP_AI_HOST" -y
drush -n config:set ai_provider_litellm.settings moderation false --input-format=yaml -y

# Bind the model roles and project them onto ai.settings + flowdrop_chat — the
# exact API the onboarding wizard uses, so the demo lands in the same state a
# human-completed setup would.
#
# The `image` role is deliberately left UNBOUND: the proxy exposes no image-
# generation model, and an unbound image role makes the media/Library AI-generate
# affordances hide themselves entirely rather than being offered and then failing.
echo "wire-ai: binding reasoning/task/fast → $DEMO_MODEL (image left unbound)"
drush -n php:eval "
  \$r = \Drupal::service('aincient_core.model_role_resolver');
  foreach (['reasoning', 'task', 'fast'] as \$role) {
    \$r->bind(\$role, 'litellm', '${DEMO_MODEL}');
  }
  \$r->project();
"

# A provider is configured now, so send visitors straight into the console.
drush -n state:set aincient_onboarding.completed 1
drush -n cache:rebuild

echo "wire-ai: done — roles → $DEMO_MODEL, image generation off, onboarding skipped."
