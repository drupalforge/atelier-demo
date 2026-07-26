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
# WHAT THIS DOES AND DOES NOT DO. It connects the PROVIDER and stops there: the
# key, the proxy host, and nothing else. It deliberately does NOT bind model roles
# or mark onboarding complete, so the visitor gets the real first-run wizard —
# name, providers (LiteLLM already showing "Connected", theirs addable), then the
# one question the models step leads with: best value / balanced / best quality.
# Choosing models is a 20-second step now that it is one question over three
# tiers, and it is the step that teaches what Atelier actually is — roles, not one
# hardcoded model. Auto-wiring it away was hiding the product's own idea.
#
# The one thing that can break that: the models step needs a non-empty chat pool,
# which the product enumerates through the provider plugin's own /model/info call
# — a path the old auto-wiring never used (it read /v1/models here and bound the
# names directly). If the proxy answers in a shape the plugin can't read, the pool
# is empty and the visitor cannot finish. So we CHECK, and fall back to the old
# behaviour when the check fails: a demo that skips onboarding still beats a demo
# nobody can get out of. Either way the outcome is logged (see dp_start_log).
#
# Env:
#   DP_AI_VIRTUAL_KEY  the trial key (unset ⇒ nothing happens, demo stays keyless)
#   DP_AI_HOST         LiteLLM proxy base URL (default https://ai.drupalforge.org)
#   DEMO_ONBOARDING    0 to skip the wizard and auto-bind models (the pre-2026-07-26
#                      behaviour); anything else, or unset, keeps the wizard.
#   DEMO_MODEL         fallback default for every role (one model everywhere)
#   DEMO_MODEL_<ROLE>  fallback per-role override, ROLE ∈ REASONING TASK FAST VISION.
#                      Comma-separated preference list; the first model the proxy
#                      actually offers wins (see dp_pick_model below). Only consulted
#                      on the fallback path.
#
set -eu -o pipefail
cd "${APP_ROOT:?APP_ROOT must be set}"
export PATH="$APP_ROOT/vendor/bin:$PATH"

DP_AI_HOST="${DP_AI_HOST:-https://ai.drupalforge.org}"

# Per-role models for the FALLBACK path only (see the header): what to bind if the
# wizard could not be handed a usable model list, or if DEMO_ONBOARDING=0 asks for
# the old auto-wired demo.
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
DEMO_MODEL_TASK="${DEMO_MODEL_TASK:-${DEMO_MODEL:-gemini/gemini-3.5-flash,openai/gpt-5.4-mini,anthropic/claude-haiku-4-5}}"
DEMO_MODEL_FAST="${DEMO_MODEL_FAST:-${DEMO_MODEL:-openai/gpt-5.4-mini,gemini/gemini-3.5-flash,anthropic/claude-haiku-4-5}}"
DEMO_MODEL_VISION="${DEMO_MODEL_VISION:-${DEMO_MODEL:-gemini/gemini-3.5-flash,openai/gpt-5.4}}"

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
drush -n cache:rebuild

# Ask the proxy which models it actually offers. This is the only place that list
# is ever visible to us — container stdout goes to Kubernetes, which we cannot
# read, so it is echoed into $APP_ROOT/logs/ by the calling script's dp_start_log.
# Purely diagnostic now (it is what the curated model document is maintained
# against); the fallback path below also picks from it.
DP_PROXY_MODELS="$(
  curl -fsS -m 20 -H "Authorization: Bearer ${DP_AI_VIRTUAL_KEY}" \
    "${DP_AI_HOST%/}/v1/models" 2>/dev/null \
    | php -r '$d = json_decode(stream_get_contents(STDIN), TRUE) ?: []; foreach ($d["data"] ?? [] as $m) { if (!empty($m["id"])) { echo $m["id"], "\n"; } }' 2>/dev/null \
    || true
)"
if [ -n "$DP_PROXY_MODELS" ]; then
  echo "wire-ai: $DP_AI_HOST offers $(printf '%s\n' "$DP_PROXY_MODELS" | wc -l | tr -d ' ') models (per /v1/models):"
  printf '  %s\n' $DP_PROXY_MODELS
else
  echo "wire-ai: WARNING — could not read $DP_AI_HOST/v1/models."
fi

# --- Can the wizard actually offer models? ----------------------------------
# The question is NOT what /v1/models says above, it is what the PRODUCT sees:
# ProviderConnector::modelsForStored('litellm') → the provider plugin → GET
# /model/info, whose chat list is everything with `model_info.mode == "chat"`.
# Ask exactly that, so the answer is the one the visitor's models step will get.
# Marker-delimited so a stray drush notice can't be read as a model count.
DP_WIZARD_MODELS=0
if [ "${DEMO_ONBOARDING:-1}" != "0" ]; then
  # `|| true`: a provider that throws must land on the fallback path, not kill the
  # container start (set -e would otherwise abort on the substitution).
  DP_PROBE="$(
    drush -n php:eval "
      try {
        \$models = \Drupal::service('aincient_onboarding.provider_connector')->modelsForStored('litellm');
        print 'ATELIER_CHAT_MODELS=' . count(\$models['chat']);
      }
      catch (\Throwable \$e) {
        print 'ATELIER_CHAT_MODELS=0 — ' . \$e->getMessage();
      }
    " 2>&1 || true
  )"
  echo "wire-ai: product-side model probe: $DP_PROBE"
  DP_WIZARD_MODELS="$(printf '%s' "$DP_PROBE" | sed -n 's/.*ATELIER_CHAT_MODELS=\([0-9]\{1,\}\).*/\1/p' | head -1)"
  [ -n "$DP_WIZARD_MODELS" ] || DP_WIZARD_MODELS=0
fi

if [ "$DP_WIZARD_MODELS" -gt 0 ]; then
  # The wizard can do its job: leave the model roles UNBOUND and onboarding
  # INCOMPLETE, so the visitor lands on the real first run. Nothing else to do —
  # the provider is connected and its catalogue is readable.
  echo "wire-ai: the wizard's model list resolves ($DP_WIZARD_MODELS chat models) — leaving onboarding to the visitor."
  # Neither the bindings nor the completion flag is touched here — which also means
  # a restart never undoes onboarding a visitor already finished.
  echo "wire-ai: done — provider connected; model roles and the onboarding flag left alone."
  exit 0
fi

if [ "${DEMO_ONBOARDING:-1}" = "0" ]; then
  echo "wire-ai: DEMO_ONBOARDING=0 — auto-binding models and skipping the wizard."
else
  echo "wire-ai: WARNING — the product cannot enumerate the proxy's chat models (${DP_AI_HOST%/}/model/info),"
  echo "wire-ai:           so the models step would be empty. Falling back to auto-bound roles."
fi

# --- Fallback: bind the roles ourselves -------------------------------------
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
