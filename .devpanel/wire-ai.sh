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
#   DEMO_MODEL         default for every role (one model everywhere)
#   DEMO_MODEL_<ROLE>  per-role override, ROLE ∈ REASONING TASK FAST VISION.
#                      Comma-separated preference list; the first model the proxy
#                      actually offers wins (see dp_pick_model below).
#
set -eu -o pipefail
cd "${APP_ROOT:?APP_ROOT must be set}"
export PATH="$APP_ROOT/vendor/bin:$PATH"

DP_AI_HOST="${DP_AI_HOST:-https://ai.drupalforge.org}"

# Per-role models, mirroring the defaults the onboarding wizard suggests to a human
# who connects OpenAI + Gemini — a capable model where it counts and a cheap one
# where it does not, rather than one budget model everywhere:
#
#   reasoning → page and brand builds: structured JSON + tool calling
#   task      → the everyday console turn
#   fast      → trivial classify/extract steps
#   vision    → alt text and captions. Safe to bind: it carries no operation-type
#               projection, so it cannot clobber the tier that owns chat vision.
#
# Each is a *preference list*, because the proxy decides which model IDs exist and
# this repo cannot know: the list is walked against the proxy's own /v1/models and
# the first one actually offered is bound, with claude-haiku-4-5 as a known-good
# tail. DEMO_MODEL, if set, replaces all four (the old behaviour: one model
# everywhere).
DEMO_MODEL_REASONING="${DEMO_MODEL_REASONING:-${DEMO_MODEL:-openai/gpt-5.4,anthropic/claude-haiku-4-5}}"
DEMO_MODEL_TASK="${DEMO_MODEL_TASK:-${DEMO_MODEL:-gemini/gemini-flash-latest,openai/gpt-5.4-mini,anthropic/claude-haiku-4-5}}"
DEMO_MODEL_FAST="${DEMO_MODEL_FAST:-${DEMO_MODEL:-openai/gpt-5.4-mini,gemini/gemini-flash-latest,anthropic/claude-haiku-4-5}}"
DEMO_MODEL_VISION="${DEMO_MODEL_VISION:-${DEMO_MODEL:-gemini/gemini-3.5-flash,gemini/gemini-flash-latest,openai/gpt-5.4}}"

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

# Ask the proxy which models it actually offers. This is the only place that list
# is ever visible to us — container stdout goes to Kubernetes, which we cannot
# read, so it is echoed into $APP_ROOT/logs/ by the calling script's dp_start_log.
# A failure here is not fatal: we fall back to binding each role's first
# preference, which is exactly what this script did before.
DP_PROXY_MODELS="$(
  curl -fsS -m 20 -H "Authorization: Bearer ${DP_AI_VIRTUAL_KEY}" \
    "${DP_AI_HOST%/}/v1/models" 2>/dev/null \
    | php -r '$d = json_decode(stream_get_contents(STDIN), TRUE) ?: []; foreach ($d["data"] ?? [] as $m) { if (!empty($m["id"])) { echo $m["id"], "\n"; } }' 2>/dev/null \
    || true
)"
if [ -n "$DP_PROXY_MODELS" ]; then
  echo "wire-ai: $DP_AI_HOST offers $(printf '%s\n' "$DP_PROXY_MODELS" | wc -l | tr -d ' ') models:"
  printf '  %s\n' $DP_PROXY_MODELS
else
  echo "wire-ai: WARNING — could not read $DP_AI_HOST/v1/models; binding each role's first preference unverified."
fi

# Walk a comma-separated preference list and print the first model the proxy
# offers. No blind picking if none match: fall back to the first preference and say
# so loudly, so a wrong model ID shows up as one warning in the log rather than as
# a demo that 404s on every turn with no explanation.
dp_pick_model() {
  local role="$1" prefs="$2" first="" candidate=""
  local IFS=,
  for candidate in $prefs; do
    [ -n "$first" ] || first="$candidate"
    if [ -z "$DP_PROXY_MODELS" ] || printf '%s\n' "$DP_PROXY_MODELS" | grep -Fxq "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    echo "wire-ai: $role — '$candidate' is not offered by the proxy, trying the next preference." >&2
  done
  echo "wire-ai: WARNING — $role: none of [$prefs] is offered by $DP_AI_HOST; binding '$first' anyway." >&2
  printf '%s' "$first"
}

MODEL_REASONING="$(dp_pick_model reasoning "$DEMO_MODEL_REASONING")"
MODEL_TASK="$(dp_pick_model task "$DEMO_MODEL_TASK")"
MODEL_FAST="$(dp_pick_model fast "$DEMO_MODEL_FAST")"
MODEL_VISION="$(dp_pick_model vision "$DEMO_MODEL_VISION")"

# Bind the model roles and project them onto ai.settings + flowdrop_chat — the
# exact API the onboarding wizard uses, so the demo lands in the same state a
# human-completed setup would.
#
# The `image` role is deliberately left UNBOUND: the proxy exposes no image-
# generation model, and an unbound image role makes the media/Library AI-generate
# affordances hide themselves entirely rather than being offered and then failing.
echo "wire-ai: binding reasoning → $MODEL_REASONING"
echo "wire-ai: binding task      → $MODEL_TASK"
echo "wire-ai: binding fast      → $MODEL_FAST"
echo "wire-ai: binding vision    → $MODEL_VISION"
echo "wire-ai: leaving image unbound (no image model on the proxy)"
drush -n php:eval "
  \$r = \Drupal::service('aincient_core.model_role_resolver');
  \$r->bind('reasoning', 'litellm', '${MODEL_REASONING}');
  \$r->bind('task', 'litellm', '${MODEL_TASK}');
  \$r->bind('fast', 'litellm', '${MODEL_FAST}');
  \$r->bind('vision', 'litellm', '${MODEL_VISION}');
  \$r->project();
"

# A provider is configured now, so send visitors straight into the console.
drush -n state:set aincient_onboarding.completed 1
drush -n cache:rebuild

echo "wire-ai: done — reasoning=$MODEL_REASONING task=$MODEL_TASK fast=$MODEL_FAST vision=$MODEL_VISION, image generation off, onboarding skipped."
