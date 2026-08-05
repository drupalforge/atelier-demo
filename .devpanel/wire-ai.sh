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
# WHICH PROVIDER THIS CONNECTS, AND WHY IT CHANGED. It used to be
# `ai_provider_litellm`, a `drupal/ai` provider plugin. Atelier is off `drupal/ai`
# entirely (DECISIONS 0281–0299): inference runs on our own adapters over
# symfony/ai, there is no `ai` module on the site, and `litellm` is no longer a
# provider id at all. The proxy is now reached through `openai_compatible` — the
# adapter for anything that speaks the OpenAI chat-completions shape, which is
# precisely what a LiteLLM proxy is. Nothing is installed: the set of providers
# Atelier can serve IS the set of tagged adapters, so connecting one means storing
# a credential and a base URL, and that is all this script does.
#
# WHAT THIS DOES AND DOES NOT DO. It connects the PROVIDER, and declares which
# vendors this proxy cannot actually serve (see "Which vendors can this proxy
# actually SERVE?" below). It deliberately does NOT bind model roles
# or mark onboarding complete, so the visitor gets the real first-run wizard —
# name, providers (the proxy already showing "Connected", theirs addable), then the
# one question the models step leads with: best value / balanced / best quality.
# Choosing models is a 20-second step now that it is one question over three
# tiers, and it is the step that teaches what Atelier actually is — roles, not one
# hardcoded model. Auto-wiring it away was hiding the product's own idea.
#
# The one thing that can break that: the models step needs a non-empty chat pool,
# which the product enumerates through the adapter's own /v1/models call. If the
# proxy answers in a shape the adapter can't read, the pool is empty and the
# visitor cannot finish. So we CHECK, and fall back to the old behaviour when the
# check fails: a demo that skips onboarding still beats a demo nobody can get out
# of. Either way the outcome is logged (see dp_start_log).
#
# KNOWN DEGRADATION, ACCEPTED. `openai_compatible` reports isProxy() === FALSE,
# because in the general case its model ids are the upstream vendor's own
# (`deepseek-v4-pro`), not vendor-namespaced. THIS proxy namespaces them
# (`openai/gpt-5.4`), but the product cannot know that per-deployment, so the
# proxy-aware halves of our curation do not fire here: the wizard's tier presets
# cannot match a model the curated document names, and every model carries the
# `untested` badge. The demo still works; it is just less opinionated than a
# direct-key install.
#
# What that degradation is NOT any more is "all three tiers are the same model".
# That was a second, separate hole, found on the first live demo and fixed in the
# product: `openai_compatible` had no ModelRoles::tierHints() entry, so with the
# document unreachable AND no hints every role ended at "the first model in the
# pool" — which on this proxy was `openai/*`, a LiteLLM wildcard GROUP that no
# turn could have called. The adapter now drops wildcard groups and non-chat
# modalities from its catalogue, and the provider has the family needles
# `litellm` used to carry. If a demo ever shows four identical roles again, that
# entry is the first thing to check.
#
# The other piece of proxy-awareness that survives without isProxy() is the
# dead-vendor guard below, because it is re-expressed in this provider's own
# identity.
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

# The provider id the proxy is connected as. Not `litellm` — see the header.
DP_PROVIDER='openai_compatible'

# Per-role model preferences for THIS proxy.
#
#   reasoning → page and brand builds: structured JSON + tool calling
#   task      → the everyday console turn
#   fast      → trivial classify/extract steps
#   vision    → alt text and captions. Safe to bind: it carries no operation-type
#               projection, so it cannot clobber the tier that owns chat vision.
#
# Each is an ordered *preference list*, because the proxy decides which model IDs
# exist and this repo cannot know. They are used TWICE: written to
# `aincient_core.model_preferences:prefer` so the wizard's tiers land here (see
# below), and walked against /v1/models on the fallback path. DEMO_MODEL, if set,
# replaces all four (the old behaviour: one model everywhere).
#
# WHY DEEPSEEK FOR THE THREE CHAT TIERS (2026-08-06). Confirmed working by hand
# on a live demo instance: `deepseek-v4-pro` for High thinking and
# `deepseek-v4-flash` for Task/Fast completed real turns. That hand test is the
# evidence that matters and this script cannot produce it — the vendor probe below
# sends NO token cap, so a model answering the probe says nothing about whether it
# accepts `max_tokens`, which every real Atelier turn sends. Only a turn through
# the product tests that field. The ids are the proxy's own, read back from
# /v1/models rather than guessed.
# `deepseek-chat` trails each list as the fallback: it is the one deepseek id the
# probe has repeatedly seen answer, so it is the safest second choice if the v4
# ids are ever withdrawn.
#
# VISION IS DEEPSEEK TOO — a deliberate call, with the risk written down. The
# `vision` role is the one tier the product refuses to infer: `InstallCapabilities`
# lights the **Describe** chip only when vision is EXPLICITLY pinned, so that sight
# is never promised from a guess. That makes this pin a claim, not a default: if
# `deepseek-v4-flash` cannot read an image, the chip lights and alt text fails at
# call time, which is the confidently-wrong shape the chip was built to prevent.
# Chosen anyway, because the alternative was worse in practice — the vision-capable
# vendors this proxy could serve are the two it cannot: anthropic 401s on every
# model and gemini rate-limits its own probe.
# `openai/gpt-4o` trails as the FALLBACK rather than another deepseek id, and that
# ordering is the point: if the v4 id is ever withdrawn, vision must land on
# something known to read images, not on `deepseek-chat`, which is no likelier to
# be multimodal. **If alt text starts failing on the demo, this is the first line
# to look at** — a Describe chip lit over a text-only model.
#
# WHY NOT GPT-5, still true and still the trap to know. GPT-5 models reject
# `max_tokens` (they want `max_completion_tokens`), and every Atelier turn sends
# `max_tokens` (`ChatCompleter`, `SymfonyAiReasoner`), which
# `OpenAiCompatibleAdapter` passes through verbatim because that spelling IS the
# chat-completions shape. A gpt-5 id here would enumerate fine, bind fine, and 400
# on the first real turn.
# Anthropic is deliberately absent: the probe below routinely finds no working
# Anthropic credential on this host and excludes the whole vendor.
DEMO_MODEL_REASONING="${DEMO_MODEL_REASONING:-${DEMO_MODEL:-deepseek/deepseek-v4-pro,deepseek/deepseek-chat}}"
DEMO_MODEL_TASK="${DEMO_MODEL_TASK:-${DEMO_MODEL:-deepseek/deepseek-v4-flash,deepseek/deepseek-chat}}"
DEMO_MODEL_FAST="${DEMO_MODEL_FAST:-${DEMO_MODEL:-deepseek/deepseek-v4-flash,deepseek/deepseek-chat}}"
DEMO_MODEL_VISION="${DEMO_MODEL_VISION:-${DEMO_MODEL:-deepseek/deepseek-v4-flash,openai/gpt-4o}}"

if [ -z "${DP_AI_VIRTUAL_KEY:-}" ]; then
  echo "wire-ai: DP_AI_VIRTUAL_KEY is unset — leaving the demo keyless (the onboarding wizard will show)."
  exit 0
fi

# --- Is this graft new enough to wire? --------------------------------------
# The whole script assumes the adapter set. An older grafted atelier-cms image
# predates it and has no `openai_compatible` provider, in which case every step
# below would "succeed" while wiring nothing — the failure mode that is worth a
# hard stop, because it surfaces to a visitor as a demo with no AI and no
# explanation. Ask the product directly.
# Marker-matched rather than exit-code-matched: `exit()` inside php:eval ends the
# drush process mid-bootstrap, and its shutdown handlers are entitled to rewrite
# the status. A string we printed ourselves cannot be rewritten by anything.
DP_HAS_ADAPTER="$(
  drush -n php:eval "
    print isset(\Drupal::service('aincient_core.inference.registry')->adapters()['${DP_PROVIDER}'])
      ? 'ATELIER_ADAPTER=yes' : 'ATELIER_ADAPTER=no';
  " 2>&1 || true
)"
if ! printf '%s' "$DP_HAS_ADAPTER" | grep -q 'ATELIER_ADAPTER=yes'; then
  echo "wire-ai: adapter probe said: $DP_HAS_ADAPTER" >&2
  echo "wire-ai: FATAL — this Atelier graft has no '${DP_PROVIDER}' provider." >&2
  echo "wire-ai:         Bump .devpanel/Dockerfile's atelier-cms tag to an image built" >&2
  echo "wire-ai:         after the drupal/ai teardown (DECISIONS 0295–0299)." >&2
  exit 1
fi
echo "wire-ai: connecting the proxy as '${DP_PROVIDER}'"

# --- Is this graft new enough to read the key from the environment? ---------
# The credential arrives through the ENVIRONMENT, bridged from DP_AI_VIRTUAL_KEY
# to ATELIER_<PROVIDER>_API_KEY in .devpanel/settings.devpanel.php. Nothing here
# writes a credential — which is the point: the secret never reaches config,
# State or the database, so it cannot end up in the image's dump.
#
# This replaces the env-provider `key.key` entity plus the
# `aincient.provider.<id>: api_key` pointer that expressed the same intent in
# three moving parts (DECISIONS 0339). A graft older than that support ignores
# the variable entirely and would leave a keyless demo with no explanation, so
# ask the product directly — same marker-matched idiom as the adapter probe
# above, and for the same reason.
DP_HAS_ENV_CREDENTIALS="$(
  drush -n php:eval "
    print method_exists(\Drupal::service('aincient_core.inference.registry'), 'isEnvironmentManaged')
      ? 'ATELIER_ENV_CREDENTIALS=yes' : 'ATELIER_ENV_CREDENTIALS=no';
  " 2>&1 || true
)"
if ! printf '%s' "$DP_HAS_ENV_CREDENTIALS" | grep -q 'ATELIER_ENV_CREDENTIALS=yes'; then
  echo "wire-ai: env-credential probe said: $DP_HAS_ENV_CREDENTIALS" >&2
  echo "wire-ai: FATAL — this Atelier graft cannot read credentials from the environment." >&2
  echo "wire-ai:         Bump .devpanel/Dockerfile's atelier-cms tag to an image built" >&2
  echo "wire-ai:         after DECISIONS 0339." >&2
  exit 1
fi

# Confirm the bridge actually reached the product, rather than assuming it: a
# settings file that did not load, or a DP_PROVIDER mismatch, both look exactly
# like a missing key at the first turn and nowhere earlier.
DP_ENV_SEEN="$(
  DP_PROVIDER="$DP_PROVIDER" drush -n php:eval "
    print \Drupal::service('aincient_core.inference.registry')->isEnvironmentManaged(getenv('DP_PROVIDER'))
      ? 'ATELIER_ENV_KEY=yes' : 'ATELIER_ENV_KEY=no';
  " 2>&1 || true
)"
if ! printf '%s' "$DP_ENV_SEEN" | grep -q 'ATELIER_ENV_KEY=yes'; then
  echo "wire-ai: env-key probe said: $DP_ENV_SEEN" >&2
  echo "wire-ai: FATAL — DP_AI_VIRTUAL_KEY did not reach Atelier as ATELIER_$(printf '%s' "$DP_PROVIDER" | tr '[:lower:]' '[:upper:]')_API_KEY." >&2
  echo "wire-ai:         Check that .devpanel/settings.devpanel.php is the settings file in use." >&2
  exit 1
fi
echo "wire-ai: ${DP_PROVIDER} reads its key from the environment"

# Clear the three-part wiring this replaced, if a volume or an older dump still
# carries it. Harmless while it lingers — the environment is consulted first —
# but leaving it would keep the `aincient.provider.*` read path alive in the
# product for a demo that no longer uses it, which is the whole point of moving.
if drush -n config:get "aincient.provider.${DP_PROVIDER}" api_key >/dev/null 2>&1; then
  echo "wire-ai: removing the superseded credential pointer + key entity"
  DP_PROVIDER="$DP_PROVIDER" drush -n php:eval '
    \Drupal::configFactory()->getEditable("aincient.provider." . getenv("DP_PROVIDER"))->delete();
  '
  drush -n config:delete "key.key.${DP_PROVIDER}_default_key" 2>/dev/null || true
fi

# The base URL is NOT a secret and is stored the ordinary way, under the same
# State convention a wizard-connected OpenAI-compatible endpoint uses — so a
# headlessly wired demo and a hand-connected install differ only in where the
# secret lives.
echo "wire-ai: pointing ${DP_PROVIDER} at $DP_AI_HOST"
drush -n state:set "aincient.${DP_PROVIDER}_endpoint" "$DP_AI_HOST"
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

# --- Which vendors can this proxy actually SERVE? ---------------------------
# /v1/models is a catalogue, not a promise. A LiteLLM proxy lists a model group
# whether or not it holds a working upstream credential for that vendor, so a
# model can be advertised, chosen by the wizard, bound to a role, and only then
# fail every turn with an authentication error from the vendor — which reads to a
# visitor as "Atelier is broken", because nothing before that moment could tell
# them otherwise. (Observed 2026-07-26: every anthropic/* model on this host
# returned Anthropic's own "API key is invalid" while openai/* and gemini/* were
# fine, so all three tiers, whose picks fall through to Anthropic here, were dead.)
#
# So: ask. One 1-token completion per vendor, and anything that answers with an
# AUTH error is declared unusable to the product through
# `aincient_core.model_preferences` — a config object that exists precisely so a
# deployment can state what our published recommendations cannot know about it.
#
# Two deliberate conservatisms:
#   - only an auth signal excludes. A 400/404 means we picked a bad probe model,
#     not that the vendor is unreachable, and excluding a whole vendor on an
#     ambiguous failure is worse than leaving it in.
#   - the list is rebuilt from scratch on every container start, so the day the
#     credential is fixed the exclusion disappears by itself. Nothing here needs
#     editing when the upstream problem goes away.
dp_probe_vendor() {
  # Prints the vendor id when it must be AVOIDED; silent when it is usable.
  #
  # The request carries NO token cap on purpose. `max_tokens` is rejected outright
  # by OpenAI's GPT-5 family (they want `max_completion_tokens`), which on the
  # first real run made every openai/* probe return 400 and report "no model
  # answered" for a vendor that demonstrably works. Sending neither is the one
  # shape every vendor behind this proxy accepts; a handful of "hi" replies per
  # container start is not a cost worth a compatibility matrix.
  local vendor="$1" candidate body status tried=0 saw_auth_error=0

  # Two filters, both learned from the first real run against this proxy:
  #   - `vendor/*` — LiteLLM publishes a wildcard model GROUP per vendor and it
  #     comes back from /v1/models looking exactly like a model id. Probing it
  #     spends a candidate slot to earn a 400 that means nothing.
  #   - non-chat ids, which would fail for a reason unrelated to the credential.
  # `|| true`: a vendor whose every id is filtered out leaves grep exiting 1, and
  # with `set -e -o pipefail` that would abort the container start over nothing.
  for candidate in $(
    printf '%s\n' $DP_PROXY_MODELS \
      | grep "^${vendor}/" \
      | grep -v '/\*$' \
      | grep -Eiv 'container|audio|realtime|tts|embed|image|lyria|robotics|computer-use|search|whisper|guard' \
      | head -3 || true
  ); do
    tried=$((tried + 1))
    body="$(
      curl -sS -m 25 -o - -w '\nHTTP_STATUS:%{http_code}' \
        -H "Authorization: Bearer ${DP_AI_VIRTUAL_KEY}" \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"${candidate}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        "${DP_AI_HOST%/}/v1/chat/completions" 2>/dev/null || true
    )"
    status="$(printf '%s' "$body" | sed -n 's/.*HTTP_STATUS:\([0-9]\{1,\}\).*/\1/p' | tail -1)"

    if [ "$status" = "200" ]; then
      echo "wire-ai: probe ${vendor} — OK (via ${candidate})." >&2
      return 0
    fi
    # LiteLLM relays the upstream body, so the vendor's own wording is what we
    # match on, alongside the proxy's exception class and the bare status codes.
    if [ "$status" = "401" ] || [ "$status" = "403" ] \
      || printf '%s' "$body" | grep -qiE 'authentication_error|AuthenticationError|api key|invalid.*key|unauthorized'; then
      saw_auth_error=1
      echo "wire-ai: probe ${vendor} — auth failure on ${candidate} (status ${status:-none})." >&2
      continue
    fi
    echo "wire-ai: probe ${vendor} — ${candidate} failed with status ${status:-none} (not an auth error; ignoring)." >&2
  done

  if [ "$tried" -eq 0 ]; then
    echo "wire-ai: probe ${vendor} — no chat-shaped model to probe; leaving it alone." >&2
    return 0
  fi
  if [ "$saw_auth_error" -eq 1 ]; then
    printf '%s' "$vendor"
    return 0
  fi
  echo "wire-ai: probe ${vendor} — no model answered, but nothing looked like an auth failure; leaving it alone." >&2
}

DP_DEAD_VENDORS=""
if [ -n "$DP_PROXY_MODELS" ]; then
  for dp_vendor in $(printf '%s\n' $DP_PROXY_MODELS | sed -n 's|^\([^/][^/]*\)/.*|\1|p' | sort -u); do
    dp_dead="$(dp_probe_vendor "$dp_vendor")"
    [ -z "$dp_dead" ] || DP_DEAD_VENDORS="${DP_DEAD_VENDORS} ${dp_dead}"
  done
fi
DP_DEAD_VENDORS="$(printf '%s' "$DP_DEAD_VENDORS" | sed 's/^ *//')"

if [ -n "$DP_DEAD_VENDORS" ]; then
  echo "wire-ai: unusable on this proxy (auth): $DP_DEAD_VENDORS — declaring them in aincient_core.model_preferences."
else
  echo "wire-ai: every vendor this proxy lists answered; declaring no exclusions."
fi

# Rebuild `avoid` AND `prefer` wholesale — including back to empty.
#
# `avoid` states what this proxy CANNOT do. `prefer` states what it should reach
# for, and it is written here for a reason the curated document cannot cover:
# through `openai_compatible` the document is UNREACHABLE (its candidates are
# tried against declared proxies only, and this provider reports
# isProxy() === FALSE), so without `prefer` the tiers fall to
# ModelRoles::tierHints() — family needles that will happily land on a gpt-5 id
# this proxy enumerates and then 400s on, because of the `max_tokens` spelling
# documented at the top of this file. The four ids in DEMO_MODEL_* were verified
# by hand to answer here; `prefer` is the supported way for a deployment to say
# so, resolved as its own pass ahead of everything else.
#
# MEASURED, against a pool shaped like this proxy's (2026-08-03). Without
# `prefer`, the tier hints put BOTH reasoning and task on `openai/gpt-5.6-sol` —
# a gpt-5 id, i.e. exactly the 400 described above. So this is not a refinement
# of a working demo; it is what makes the demo work at all.
#
# `prefer` is keyed by ROLE, not by profile, so all three profiles resolve
# identically with it set. That costs nothing here, and it is worth being precise
# about why: they were ALREADY identical without it. Tier hints carry no notion
# of a profile, and the curated document — the only thing that distinguishes
# best value from best quality — cannot be reached through this provider at all.
# The three-profile collapse is owned by isProxy(), not by this write; removing
# `prefer` would restore nothing except the 400.
#
# THE PATTERN SHAPE MATTERS, and it changed with the provider. It used to be
# `anthropic:*`, which worked because `litellm` was a declared proxy provider and
# ModelPresetResolver::isAvoided() therefore tested each pool entry under a SECOND
# identity — the vendor named inside its own model id. `openai_compatible` is not
# a declared proxy (its ids are usually the vendor's own, unnamespaced), so that
# second identity is never derived and `anthropic:*` would match nothing at all —
# a guard that silently stops guarding, which is worse than no guard.
#
# So the exclusion is written in THIS provider's own identity instead:
# `openai_compatible:anthropic/`. isAvoided() splits on the first colon, giving
# vendor `openai_compatible` (which every pool entry here matches) and needle
# `anthropic/`, and the needle test is a substring match — so it catches
# `anthropic/claude-sonnet-5` and every other model the vendor serves through
# this proxy. Same outcome, no reliance on isProxy().
DP_DEAD_VENDORS="$DP_DEAD_VENDORS" DP_PROVIDER="$DP_PROVIDER" \
DP_PREFER_REASONING="$DEMO_MODEL_REASONING" DP_PREFER_TASK="$DEMO_MODEL_TASK" \
DP_PREFER_FAST="$DEMO_MODEL_FAST" DP_PREFER_VISION="$DEMO_MODEL_VISION" \
drush -n php:eval '
  $config = \Drupal::configFactory()->getEditable("aincient_core.model_preferences");
  if ($config->isNew()) {
    // An older grafted image, from before model preferences existed.
    print "ATELIER_PREFS=unsupported";
    return;
  }
  $provider = (string) getenv("DP_PROVIDER");
  $dead = array_values(array_filter(explode(" ", (string) getenv("DP_DEAD_VENDORS"))));
  $config->set("avoid", array_map(
    static fn (string $v): string => $provider . ":" . $v . "/",
    $dead,
  ));

  // The same comma-separated lists the fallback path walks, qualified with the
  // provider id `prefer` is matched on. Roles whose list is empty are omitted
  // rather than written as [], so an operator can blank one via the environment
  // and get the ordinary resolution back for that role alone.
  $prefer = [];
  foreach (["reasoning", "task", "fast", "vision"] as $role) {
    $models = array_values(array_filter(array_map(
      "trim",
      explode(",", (string) getenv("DP_PREFER_" . strtoupper($role))),
    )));
    if ($models !== []) {
      $prefer[$role] = array_map(
        static fn (string $m): string => $provider . ":" . $m,
        $models,
      );
    }
  }
  $config->set("prefer", $prefer)->save();

  print "ATELIER_PREFS=" . (count($dead) ? implode(",", $dead) : "none")
    . " PREFER=" . implode(",", array_map(
      static fn (array $v): string => reset($v),
      $prefer,
    ));
' || echo "wire-ai: WARNING — could not write aincient_core.model_preferences."
echo

drush -n cache:rebuild

# --- Can the wizard actually offer models? ----------------------------------
# The question is NOT what /v1/models says above, it is what the PRODUCT sees:
# ProviderConnector::modelsForStored('openai_compatible') → the adapter →
# GET <base>/v1/models, minus anything that looks like an embedding model.
# Ask exactly that, so the answer is the one the visitor's models step will get.
# Marker-delimited so a stray drush notice can't be read as a model count.
DP_WIZARD_MODELS=0
if [ "${DEMO_ONBOARDING:-1}" != "0" ]; then
  # `|| true`: a provider that throws must land on the fallback path, not kill the
  # container start (set -e would otherwise abort on the substitution).
  DP_PROBE="$(
    drush -n php:eval "
      try {
        \$models = \Drupal::service('aincient_onboarding.provider_connector')->modelsForStored('${DP_PROVIDER}');
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
  echo "wire-ai: WARNING — the product cannot enumerate the proxy's chat models (${DP_AI_HOST%/}/v1/models),"
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

# Bind the model roles and project them, using the exact API the onboarding wizard
# uses, so the demo lands in the same state a human-completed setup would.
# project() writes the default role onto flowdrop_chat and invalidates the model
# cache — it no longer touches `ai.settings`, which does not exist on the site.
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
  \$r->bind('reasoning', '${DP_PROVIDER}', '${MODEL_REASONING}');
  \$r->bind('task', '${DP_PROVIDER}', '${MODEL_TASK}');
  \$r->bind('fast', '${DP_PROVIDER}', '${MODEL_FAST}');
  \$r->bind('vision', '${DP_PROVIDER}', '${MODEL_VISION}');
  \$r->project();
"

# A provider is configured now, so send visitors straight into the console.
drush -n state:set aincient_onboarding.completed 1
drush -n cache:rebuild

echo "wire-ai: done — reasoning=$MODEL_REASONING task=$MODEL_TASK fast=$MODEL_FAST vision=$MODEL_VISION, image generation off, onboarding skipped."
