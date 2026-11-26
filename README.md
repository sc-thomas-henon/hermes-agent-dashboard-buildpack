# Hermes Agent Dashboard Buildpack for Scalingo

Buildpack that deploys the **Hermes web dashboard** (`hermes dashboard`) on
Scalingo. The agent/gateway variant lives in
[hermes-agent-buildpack](https://github.com/sc-thomas-henon/hermes-agent-buildpack).

Note: this repository must be **public** — the Scalingo builder clones
`BUILDPACK_URL` over HTTPS without credentials.

Custom [Scalingo](https://scalingo.com) buildpack that deploys
[Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research)
as a web application. Target stack: **scalingo-26** (Ubuntu 26.04 LTS), the
current default stack.

The buildpack follows the classic Scalingo/Heroku buildpack contract described
in [Use a Custom Buildpack](https://doc.scalingo.com/platform/deployment/buildpacks/custom):
`bin/detect`, `bin/compile`, `bin/release`, plus a `.profile.d` script written
into the app at build time.

## Usage

Set the `BUILDPACK_URL` environment variable on your Scalingo application:

```
scalingo --app my-app env-set BUILDPACK_URL=https://github.com/sc-thomas-henon/hermes-agent-buildpack
```

To test a branch instead of the default branch, append `#branch-name` to the
URL. Then push your application as usual.

## Detection

The buildpack applies when the application root contains:

- a `requirements.txt` or `pyproject.toml` mentioning `hermes-agent`
  (e.g. `hermes-agent @ git+https://github.com/NousResearch/hermes-agent.git@v0.23.4`), or
- a `Hermesfile` marker file.

## What the build does

`bin/compile`:

1. Fetches system packages (`ripgrep`, `ffmpeg`) the Scalingo way:
   `bin/compile` runs as a non-root user, so instead of `apt-get install` it
   downloads the .debs with `apt-get -d` (apt state/cache redirected into the
   build cache) and extracts them with `dpkg -x` into `/app/.apt`, exposed at
   runtime via `.profile.d/000_apt.sh`. Extra packages can be listed in an
   `Aptfile` at the app root (path overridable with `APT_FILE_MANIFEST`).
   `python3.14` itself comes from the scalingo-26 base image.
2. Creates a virtualenv in `/app/.venv` using the stack's Python 3.14
   (on stacks without it, a uv-managed Python 3.14 is installed into the
   build cache as a fallback).
3. Installs `hermes-agent` from a **pinned git tag** (`HERMES_AGENT_VERSION`).
   Upstream only supports source-checkout installs (its `setup.py` refuses to
   build wheels, and PyPI is stale), so the buildpack clones the tag, ships the
   checkout as `/app/hermes-src`, and installs it editable into the venv with
   `uv sync --frozen` against upstream's `uv.lock` (their `[tool.uv]`
   override-dependencies, e.g. Pillow, only apply in that mode). The clone is
   cached in the build cache and only re-fetched when the tag changes.
4. Installs the app's `requirements.txt` if present (`hermes-agent` lines are
   filtered out — the buildpack pins that version).
5. Builds the web dashboard SPA (`hermes_cli/web_dist`) from the source checkout
   with the pinned pnpm + `node scripts/build/web.mjs`, using a standalone Node.js
   >= 26 (`NODE_VERSION`, official nodejs.org tarball cached in the build cache —
   the apt `nodejs` deb is unusable from `.apt` because Debian externalizes
   builtins to `/usr/share/nodejs`; Node >= 25 also links `libatomic.so.1`,
   provided by `libatomic1` in `.apt`), since the assets are not in the git
   checkout. Node deps are cached via the pnpm store in the build cache.
5. Writes `.profile.d/hermes.sh` which exports:
   - `PATH` with `/app/.venv/bin` first,
   - `HERMES_HOME` (default `/app/.hermes`),
   - `API_SERVER_HOST=0.0.0.0` and `API_SERVER_PORT=$PORT` so the gateway's
     API server listens on the port Scalingo expects.

`bin/release` declares the default process type:

```
web: hermes dashboard --host 0.0.0.0 --port $PORT
```

`.profile.d/hermes.sh` also exports `HERMES_WEB_DIST=/app/hermes-src/hermes_cli/web_dist`:
with it set, `hermes dashboard` serves the prebuilt dist instead of rebuilding at
boot (a runtime rebuild cannot replace the dist directory on the read-only image
layer — EXDEV — and would need Node at runtime). The web build runs with the same
Node version PM pins in `pm/lock.json`, so the build receipt stays valid.

The dashboard is fail-closed: set `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`,
`HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` and `HERMES_DASHBOARD_BASIC_AUTH_SECRET`
as app env vars or it refuses to start. Do NOT set `API_SERVER_KEY` on this app
(it would enable the api_server platform on the same `$PORT`).

Provider API keys set as app config vars (any `*_API_KEY`, e.g.
`OPENROUTER_API_KEY`) are bridged at container boot into `$HERMES_HOME/.env`
(mode 0600) by `.profile.d/hermes.sh`, because the dashboard backend resolves
provider credentials through the profile secret scope (`<home>/.env`) and, under
multiplexing, a scope miss never falls back to `os.environ`.

Provide your own `Procfile` in the app to override it.

## Configuration variables

| Variable | Default | Description |
| --- | --- | --- |
| `HERMES_AGENT_VERSION` | `v0.23.4` (see `conf/versions.sh`) | Git tag of NousResearch/hermes-agent to install |
| `APT_FILE_MANIFEST` | `<app>/Aptfile` | Extra apt packages file |
| `BUILDPACK_DEBUG` | unset | Set to any value for `set -x` in compile |
| `HERMES_UV_EXTRAS` | unset | uv extras from upstream's `uv.lock` at compile time (e.g. `messaging edge-tts` for bots + voice) |
| `HERMES_STT_PROVIDER` / `HERMES_STT_LANGUAGE` | unset | Baked into `/app/.hermes/config.yaml` as `stt.provider` / `stt.language` |
| `HERMES_TTS_PROVIDER` / `HERMES_TTS_VOICE` | unset | Baked as `tts.provider` / `tts.edge.voice` |
| `HERMES_VOICE_AUTO_TTS` / `HERMES_VOICE_AUTO_TTS_MODE` | unset | Baked as `voice.auto_tts` / `voice.auto_tts_mode` |

These `HERMES_*` vars are compile-time only (baked `config.yaml`, ephemeral fs);
credentials (`*_API_KEY`, `*_BOT_TOKEN`, `VOICE_TOOLS_OPENAI_KEY`) stay env-only
and are bridged into `$HERMES_HOME/.env` (0600) at container boot.

Note: the Hermes source checkout (~330 MB) is shipped inside the app
(`/app/hermes-src`) because upstream does not publish installable wheels.

## Enabling the HTTP API on Scalingo (via environment variables)

No `config.yaml` is needed: Hermes enables the `api_server` platform from the
environment alone (`gateway/config_env.py` in hermes-agent). Set these as
Scalingo config vars on the app (`scalingo env-set` or `POST /v1/apps/:app/variables`):

| Variable | Example | Effect |
| --- | --- | --- |
| `API_SERVER_KEY` | `scalingo env-set API_SERVER_KEY=$(openssl rand -hex 16)` | Enables the API server (key must be ≥ 16 chars) and is the Bearer token |
| `API_SERVER_HOST` | `0.0.0.0` | Bind address (buildpack default) |
| `API_SERVER_PORT` | `$PORT` | Bind port (buildpack maps Scalingo's `$PORT` by default) |
| `API_SERVER_CORS_ORIGINS` | `https://example.com` | Optional CORS origins (CSV) |
| `API_SERVER_MODEL_NAME` | `hermes-agent` | Optional model name override |

The buildpack's `.profile.d/hermes.sh` provides the `0.0.0.0` / `$PORT`
defaults, and app config vars override them. The API is then reachable on the
application URL: `GET /v1/models`, `POST /v1/chat/completions`, … with
`Authorization: Bearer $API_SERVER_KEY`. A plain `config.yaml` in
`$HERMES_HOME` still works too and is merged underneath the env overrides.

## Deploying an app with this buildpack

- Set `BUILDPACK_URL` on the Scalingo app (optionally `#branch` to pin a
  branch). With the Scalingo API, archive deploys (`POST /v1/sources`, PUT the
  tar.gz, then `POST /v1/apps/:app/deployments` with `source_url`) require the
  tar to contain a **single top-level folder** with the app files inside.
- The gateway's HTTP platforms (`api_server`, webhooks) need `aiohttp`, which
  upstream only ships in opt-in extras; the buildpack installs the pinned
  version (`HERMES_EXTRA_PACKAGES` in `conf/versions.sh`).

## Local testing

Run the buildpack scripts in the same image Scalingo uses:

```
docker run --pull always --rm -it --env STACK=scalingo-26 \
  --volume /path/to/hermes-agent-buildpack:/buildpack \
  --volume /path/to/application:/build \
  scalingo/scalingo-26:latest bash

mkdir -p /tmp/cache /tmp/env
/buildpack/bin/detect /build
/buildpack/bin/compile /build /tmp/cache /tmp/env
/buildpack/bin/release /build
```

Or use the test harness (syntax + detect + release; `--compile` adds the full
build, needs root and network):

```
./test/run.sh           # fast checks
./test/run.sh --compile # full compile against test/fixture-app
```
