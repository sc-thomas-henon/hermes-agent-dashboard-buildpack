HERMES_AGENT_VERSION="v0.23.4"
HERMES_AGENT_REPO="https://github.com/NousResearch/hermes-agent.git"
PYTHON_VERSION="3.14"
UV_VERSION="0.13.10"
# Downloaded and extracted into .apt (see lib/apt.sh); python3.14 comes from the
# scalingo-26 base image, git/curl are already in the stack image. libatomic1 is
# linked by the standalone Node >= 25 binary (libatomic.so.1) during the web build.
APT_PACKAGES="ripgrep ffmpeg libatomic1"
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
# pnpm version pinned by hermes-agent (pm/lock.json), enforced by its preinstall.
PNPM_VERSION="12.15.0"
