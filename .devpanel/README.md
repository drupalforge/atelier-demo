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
| `create_quickstart.sh` | image build, after `init.sh` — bakes `dumps/db.sql.gz` |
| `init-container.sh` | **every container start** (registry mode) |
| `custom_package_installer.sh` | every container start, as root, before Apache |
| `wire-ai.sh` | from both `init.sh` and `init-container.sh`; idempotent |
| `settings.php` | copied over the grafted `web/sites/default/settings.php` at build time |
| `settings.devpanel.php` | the real settings — MySQL from `DB_*`, paths, trusted hosts |
| `warm` | cache warmer used by the init scripts |
| `config.yml` | DevPanel git-integration hooks (deliberately does **not** run `composer install`) |

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

The demo binds the `reasoning` / `task` / `fast` model roles to
`anthropic/claude-haiku-4-5` — the cheapest capable Claude, so a $1 trial stretches
to roughly "3 pages + 1 brand". The **`image` role is left unbound on purpose**: the
proxy exposes no image-generation model, and an unbound image role makes the
AI-image affordances hide themselves rather than fail. AI image generation needs
your own key on a self-hosted install.

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
