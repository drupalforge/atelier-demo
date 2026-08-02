# `.devpanel/` — how the Atelier demo image is built and run

This directory is the whole demo. It carries **no product code**: the Atelier tree
is grafted in from a **pinned, published `atelier-cms` image**, so the demo runs the
exact artifact we ship and cannot drift from it.

## Lifecycle

**Build** (GitHub Actions → `drupalforge/docker_publish_action`, see
`.github/workflows/docker-publish-template.yml`):

1. This repo is copied into `$APP_ROOT` (`/var/www/html`) on top of
   `devpanel/php:8.4-base`.
2. **`Dockerfile`** is appended to the action's base Dockerfile and grafts
   `/opt/drupal` out of `ATELIER_IMAGE` — the pin that decides which Atelier build
   the demo runs. It also installs the ImageMagick CLI, swaps in `settings.php`, and
   raises Apache's `Timeout` to 600s for long console turns.
3. The image is started next to MySQL 8 and **`init.sh`** runs: it verifies the
   graft, installs Atelier from `config/sync`, enables `aincient_demo` for the
   branded homepage, and calls `wire-ai.sh`.
4. **`create_quickstart.sh`** dumps the resulting database to `dumps/db.sql.gz`.
5. The container is committed and pushed as `<repo>:<branch>`.

**Run** (DevPanel, registry mode): DevPanel starts the published image and runs
**`init-container.sh`**, which imports the baked dump into that container's own
database, re-asserts the AI wiring so the container uses **its own** injected trial
key, syncs the app root into the external volume, then warms caches.

`/scripts/apache-start.sh` in the base image also runs **`custom_package_installer.sh`**
on every start, before Apache.

## Files

| File | When it runs |
|---|---|
| `Dockerfile` | image build — appended to the action's base Dockerfile. **Holds the `ATELIER_IMAGE` pin.** |
| `init.sh` | image build, once — installs Atelier from `config/sync` |
| `create_quickstart.sh` | image build, after `init.sh` — bakes `dumps/db.sql.gz` **and the immutable seed** |
| `init-container.sh` | **every container start** (registry mode) |
| `re-config.sh` | when the container is reconfigured in DevPanel, or deployed to a host |
| `custom_package_installer.sh` | every container start, as root, before Apache — **and the last-resort seed** |
| `wire-ai.sh` | from `init.sh`, `init-container.sh` and `re-config.sh`; idempotent |
| `lib.sh` | sourced by the above — logging, DB wait, `dp_ensure_site()` |
| `doctor.sh` | **manually**, on a hosted instance, when something is wrong |
| `settings.php` | copied over the grafted `web/sites/default/settings.php` at build time |
| `settings.devpanel.php` | the real settings — MySQL from `DB_*`, paths, trusted hosts |
| `warm` | cache warmer used by the init scripts |
| `config.yml` | DevPanel git-integration hooks (deliberately does **not** run `composer install`) |

## Why the seed lives at `/opt/atelier-seed/db.sql.gz`

DevPanel copies the app root into a volume and mounts that volume back **over** the app
root, and the sync excludes `.devpanel/dumps`. So the dump baked into the app root is
**gone** by the time the served container starts. If that container also gets an empty
database, nothing seeds the site and Drupal falls through to `/core/install.php` — a
broken demo, and a hole, since a visitor could complete the install as their own admin.
That is exactly what the first hosted instance did.

`create_quickstart.sh` therefore also stashes the dump at **`/opt/atelier-seed/db.sql.gz`**,
which lives in the image where no volume can shadow it. `dp_ensure_site()` in `lib.sh`
tries, in order: that seed → the in-tree dump → a **full install from `config/sync`** (the
grafted tree has `vendor/` and the config, so this always works) → and fails loudly if
even that does not produce a site. It never returns success without an installed site.

That guarantee is invoked from `init-container.sh`, `re-config.sh` **and**
`custom_package_installer.sh` — the last one because it is the only hook the base image
runs unconditionally, whichever mode the DevPanel app is set to.

## Diagnosing a hosted instance

Container stdout goes to Kubernetes, which we cannot read. So every script mirrors its
output into **`$APP_ROOT/logs/`** and, on failure, leaves a **`logs/FAILED-<script>.log`**
marker that is impossible to miss in a directory listing.

From the DevPanel terminal or code-server:

```bash
.devpanel/doctor.sh      # full read-only diagnostic; also written to logs/
ls -1t logs/             # what ran, and whether anything failed
```

`doctor.sh` checks the grafted tree, the database, Drupal's bootstrap, the ImageMagick
toolkit, the AI wiring, and HTTP from inside the container (which catches
`trusted_host_patterns` 400s that would also fail Kubernetes probes). It never prints the
trial key, only whether it is set.

## Promoting a new demo version

Bump `ARG ATELIER_IMAGE` in `Dockerfile` to a newer immutable `atelier-cms` tag
(`sha-<short>`, or `vX.Y.Z` once we tag releases) and push to `main`. That rebuilds
and republishes the demo image. `files_to_hash` in the workflow points at this
Dockerfile precisely because it carries the pin.

Nothing pins the demo to `:edge`, on purpose — the demo moves when we decide it
moves, not when `atelier-cms` `main` merges.

## Demo environment (set on the DevPanel app)

| Var | Value | Why |
|---|---|---|
| `DP_AI_VIRTUAL_KEY` | *(DevPanel-injected trial key)* | Unset ⇒ keyless demo, onboarding wizard shows. |
| `DP_AI_HOST` | `https://ai.drupalforge.org` | LiteLLM proxy base URL. |
| `WEB_ROOT` | `/var/www/html/web` | The docroot. The image defaults it, but set it explicitly. |
| `DEMO_MODEL_REASONING` | `openai/gpt-5.4,anthropic/claude-haiku-4-5` | Page/brand builds: structured JSON + tool calling. |
| `DEMO_MODEL_TASK` | `gemini/gemini-3.5-flash,openai/gpt-5.4-mini,anthropic/claude-haiku-4-5` | The everyday console turn. |
| `DEMO_MODEL_FAST` | `openai/gpt-5.4-mini,gemini/gemini-3.5-flash,anthropic/claude-haiku-4-5` | Trivial classify/extract. |
| `DEMO_MODEL_VISION` | `gemini/gemini-3.5-flash,openai/gpt-5.4` | Alt text and captions. |
| `DEMO_MODEL` | *(unset)* | If set, replaces all four — one model everywhere. |
| `DEMO_ONBOARDING` | `1` | `0` auto-binds the roles above and skips the wizard (pre-2026-07-26 behaviour). |

### The visitor chooses the models (2026-07-26)

`wire-ai.sh` connects the **provider** and nothing else: it does not bind model roles and
does not set `aincient_onboarding.completed`. A visitor therefore gets the genuine
first-run wizard — name → providers (the proxy already **Connected**, as *OpenAI-compatible
endpoint*, their own key addable) → models, where the step leads with one question over
three tiers (best value / balanced / best quality). It is a 20-second step that explains
the product's central idea; auto-wiring it away hid that, and spent the shared trial
budget on our pick rather than theirs.

**The curated document still does not resolve through this proxy, but the tiers are no
longer identical.** `ModelPresetResolver` tries the document's candidates against **proxy
providers** in a second pass, matching the vendor named inside a `vendor/model` id — and
that pass is gated on `isProxy()`, which `openai_compatible` reports as `FALSE` (its ids
are usually the vendor's own and unnamespaced; the product cannot know that *this* host
namespaces them). What was missing on top of that was any fallback at all: the provider
had no `ModelRoles::tierHints()` entry, so every role fell through to "the first model in
the pool" and all four resolved to the same id. It has one now — the same family needles
`litellm` carried — so `reasoning`, `task` and `fast` land on models of roughly the right
cost. Models still show the `untested` badge (that lookup is `isProxy()`-gated too), and
the picks are family-approximate rather than the curated document's. Closing the gap
properly needs `isProxy()` derived from the catalogue's shape.

**What still works is the dead-vendor guard,** because `wire-ai.sh` writes it in the
connected provider's own identity — `avoid: ["openai_compatible:anthropic/"]`, not
`["anthropic:*"]`. `isAvoided()` splits the pattern on its first colon and substring-matches
the remainder against the model id, so `anthropic/` catches `anthropic/claude-sonnet-5`
without any proxy identity being derived. The old `vendor:*` shape would now match nothing
at all: a guard that silently stops guarding.

**The guard on the pool.** The models step is populated the way the product reads a
catalogue — `ProviderConnector::modelsForStored('openai_compatible')` → the adapter →
`GET <base>/v1/models`, minus anything that looks like an embedding model. If the proxy
answers in a shape the adapter can't parse the pool is empty and a visitor is stranded
mid-onboarding. `wire-ai.sh` probes it, logs the count, and falls back to auto-binding the
`DEMO_MODEL_*` roles when it is zero. `doctor.sh` prints the same count.

The variables below apply **only on that fallback path**.

Each variable is a **comma-separated preference list**, not a single model. `wire-ai.sh`
asks the proxy which models it actually offers (`GET /v1/models`, using the injected
key) and binds the first list entry that exists, with `anthropic/claude-haiku-4-5` as a
known-good tail. It logs the proxy's full model list either way — the only place we can
see it — and warns if it had to fall through. The proxy decides which model IDs are
real, and this repo cannot know, so a model rename shows up as one warning in `logs/`
rather than as a demo that 404s on every turn. Since `wire-ai.sh` re-binds on every
container start, correcting a model ID is a DevPanel env change and a redeploy — no
image rebuild.

Every default is an **immutable model ID, never a floating `-latest` alias** — the same
reason the graft pins an `atelier-cms` tag instead of tracking `:edge`. A `-latest` alias
lets the proxy change the demo's model, and therefore its cost and output, with no deploy
and no trace in the logs; a pinned ID means the demo only moves when we move it.

The **`image` role stays unbound** either way: the proxy exposes no image-generation
model, so the wizard's image picker has an empty pool (the role is optional and never
blocks finishing) and the media/Library AI-generate affordances hide themselves rather
than fail. AI image generation needs your own key. On the fallback path `vision` is safe
to bind by contrast — it carries no operation-type projection, so it overrides the
default chat role for alt text without clobbering the tier that owns chat vision.

`AINCIENT_IMPORT_CONFIG` is **not** needed here. That flag exists to stop the
appliance's `converge.sh` re-asserting `config/sync` on every restart (which would
wipe the injected key). In this design converge never runs — the DevPanel scripts
own the lifecycle — so there is nothing to fence off.

## Local testing

`bin/build-local.sh` reproduces the CI build step for step, then
`.devcontainer/` runs the result the way DevPanel does. See the header of each file.

## Notes

- The trial key's **value** is never baked into the image: `wire-ai.sh` stores it as
  an **env-provider** `key.key` entity, read live from the container environment on
  each request. Only the pointer is in the database dump.
- The base image is Debian trixie, whose packaged ImageMagick 7.1.1 can encode AVIF
  once `libheif-plugin-aomenc` is installed. Every Atelier image style converts to
  AVIF, so `init.sh` **fails the build** if that is not true — better a red build
  than a demo full of broken images.
