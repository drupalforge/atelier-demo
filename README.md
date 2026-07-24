# Atelier — Drupal Forge (DevPanel) demo

A thin DevPanel wrapper that hosts a live, throwaway demo of **Atelier** on
[Drupal Forge](https://www.drupalforge.org/), with a **LiteLLM trial key wired in
automatically** so visitors don't need to bring their own AI key.

This repo carries **no product code**. DevPanel pulls the prebuilt Atelier image
from the registry and runs [`.devpanel/init.sh`](.devpanel/init.sh) after it starts;
that script layers the demo's AI key + model roles on top. The product image itself
is unchanged and still boots keyless everywhere else.

## How it works

1. DevPanel starts `ghcr.io/aincient-labs/atelier-cms:<pinned-tag>` (registry mode).
   The image's own entrypoint installs the site from its baked-in config.
2. DevPanel injects a **$1 LiteLLM trial key** as `DP_AI_VIRTUAL_KEY` and runs
   `.devpanel/init.sh`, which:
   - enables `ai_provider_litellm`,
   - stores the key as an **env-provider** Key entity (`DP_AI_VIRTUAL_KEY`, read live
     — never persisted to config/State/DB) and points the provider at
     `DP_AI_HOST` (default `https://ai.drupalforge.org`),
   - binds the `reasoning` / `task` / `fast` model roles to `anthropic/claude-haiku-4-5`
     (budget model; `image` left unbound so AI image generation is off),
   - marks onboarding complete so visitors land straight in the console.

## Required demo environment

| Var | Value | Why |
|-----|-------|-----|
| `DP_AI_VIRTUAL_KEY` | *(DevPanel-injected trial key)* | The LiteLLM key. Unset ⇒ keyless demo (wizard shows). |
| `DP_AI_HOST` | `https://ai.drupalforge.org` | LiteLLM proxy base URL. |
| **`AINCIENT_IMPORT_CONFIG`** | **`0`** | **Required.** The image re-asserts `config/sync` on every restart; without this, a restart uninstalls `ai_provider_litellm` and wipes the injected key/roles. Disabling config re-import is safe for a pinned, ephemeral demo. |

## Version control (which build the demo runs)

The demo is pinned to a **specific `atelier-cms` image tag** — bumping that pin is how
we promote a new demo build, independent of `:edge` on `main`. Set the tag in the
DevPanel registry-image config for this template. Prefer an immutable tag
(`:vX.Y.Z` or `:sha-<short>`) over `:latest`/`:edge`.

## Notes

- **No AI image generation** in the demo: the LiteLLM proxy exposes no image model,
  so `roles.image` is left empty and the media/Library AI-generate affordances hide
  themselves (they don't error). Full text/page building + brand *tokens* work.
- Budget: the $1 trial ≈ "3 pages + 1 brand" on haiku-4.5.
- Plan / rationale / decisions: `aincient-workspace/plans/forge-demo.md` (private).
- Reference this was adapted from: `github.com/drupalforge/drupal_cms_ai_demo`.
