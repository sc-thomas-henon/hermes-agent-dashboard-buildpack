HERMES_AGENT_VERSION="v0.23.4"
HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"
PYTHON_VERSION="3.14"
UV_VERSION="0.13.10"
# Downloaded and extracted into .apt (see lib/apt.sh); python3.14 comes from the
# scalingo-26 base image, git/curl are already in the stack image. libatomic1 is
# linked by the standalone Node >= 25 binary (libatomic.so.1) during the web build.
# libopus0 is the Discord voice codec (loaded from .apt via LD_LIBRARY_PATH).
# libpulse0 ships libpulsecommon-*.so, which the apt ffmpeg binary needs at load
# time (apt Recommends are not downloaded in the download-only .apt flow).
APT_PACKAGES="ripgrep ffmpeg libatomic1 libopus0 libpulse0"
# The gateway's HTTP platforms (api_server, webhooks) need aiohttp, which upstream
# only ships in opt-in extras (messaging/slack/matrix) — pin the same version.
HERMES_EXTRA_PACKAGES="aiohttp==3.14.5"
# Standalone Node.js (official nodejs.org linux tarball, see lib/web.sh), used
# only at build time to compile the web dashboard. hermes-agent requires
# node >= 26 (engines in its package.json, engineStrict in pnpm-workspace.yaml);
# we pin the exact version PM downloads at runtime (pm/lock.json) so the build
# receipt (hermes-build.json records process.versions.node) still validates.
# The apt nodejs deb cannot be used from .apt: Debian's build externalizes
# builtins to /usr/share/nodejs, which does not exist at runtime, so node
# core-dumps when running npm.
NODE_VERSION="v26.12.1"
# hermes-live-voice (npm): realtime voice gateway + dashboard plugin, opt-in
# via HERMES_LIVE_VOICE=1 (see lib/live-voice.sh). Node >= 20 required; the
# buildpack already ships NODE_VERSION above, so the gateway reuses it.
HERMES_LIVE_VOICE_VERSION="1.3.0"
# pnpm version pinned by hermes-agent (pm/lock.json), enforced by its preinstall.
PNPM_VERSION="12.15.0"
# Optional uv extras installed from the pinned tag's uv.lock, selected at compile
# time via the app env var HERMES_UV_EXTRAS (e.g. "messaging edge-tts").
# Read from ENV_DIR in lib/python.sh (bp_env).
