# Hermes Live Voice (https://github.com/bielcarpi/hermes-live-voice): a Node
# realtime voice gateway + a Python dashboard plugin ("hermes-live"), opt-in
# via HERMES_LIVE_VOICE=1 (app config var, read at build time via bp_env and
# again at runtime in .profile.d/hermes.sh).
#
# Build side (this file):
# - ships a Node.js runtime inside the slug (lib/web.sh keeps Node only in the
#   build cache; the gateway needs it at runtime and /app is the only path both
#   writable at boot and baked at deploy),
# - npm-installs the pinned hermes-live-voice package (prebuilt dist/,
#   plugins/hermes-live/),
# - copies the dashboard plugin into .hermes/plugins/hermes-live (plugins are
#   opt-in via config.yaml `plugins.enabled`; enabling at build time bakes it),
# - installs the plugin's declared Python dependencies into the venv
#   (fastapi/httpx/websockets — see plugin.yaml python_dependencies; a
#   runtime `hermes pm repair` could not survive a redeploy on the ephemeral
#   container fs),
# - appends `plugins: enabled: [hermes-live]` to .hermes/config.yaml.
#
# Runtime side (bin/compile writes it into .profile.d/hermes.sh): the gateway
# runs on 127.0.0.1:8788 under a respawn loop; the Hermes API server moves to
# 127.0.0.1:8642 so it does not share $PORT with the dashboard; the dashboard
# plugin relays the gateway same-origin (the browser never sees the loopback
# URL, a gateway token, or provider keys).

# bp_live_voice_node_dir — the Node runtime shipped in the slug.
bp_live_voice_node_dir() {
  printf '%s' "${1}/.hermes-live/node"
}

# bp_install_live_voice BUILD_DIR — installs gateway, Node runtime and plugin.
# Must run after bp_build_web_dist (shares the cached Node download) and
# bp_setup_python (VENV_DIR).
bp_install_live_voice() {
  local build_dir="$1"
  local node_arch="x64"
  case "$(uname -m)" in
    aarch64|arm64) node_arch="arm64" ;;
  esac
  local node_dir="${CACHE_DIR}/node-${NODE_VERSION}-linux-${node_arch}"
  if [ ! -x "${node_dir}/bin/node" ]; then
    status "Downloading Node.js ${NODE_VERSION} (linux-${node_arch})"
    rm -rf "${node_dir}.tmp"
    mkdir -p "${node_dir}.tmp"
    curl -fSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-${node_arch}.tar.gz" \
      | tar xz -C "${node_dir}.tmp" --strip-components=1
    mv "${node_dir}.tmp" "${node_dir}"
  fi

  status "Shipping Node.js runtime for the hermes-live-voice gateway"
  local live_root="${build_dir}/.hermes-live"
  rm -rf "${live_root}"
  mkdir -p "${live_root}"
  cp -a "${node_dir}" "${live_root}/node"

  export PATH="${node_dir}/bin:${PATH}"
  node --version

  local pkg_dir="${build_dir}/.hermes-live-voice"
  status "Installing hermes-live-voice ${HERMES_LIVE_VOICE_VERSION} (npm)"
  rm -rf "${pkg_dir}"
  mkdir -p "${pkg_dir}"
  npm_config_cache="${CACHE_DIR}/npm-cache" \
    npm install --omit=dev --no-audit --no-fund --loglevel=warn \
      --prefix "${pkg_dir}" "hermes-live-voice@${HERMES_LIVE_VOICE_VERSION}"

  local plugin_src="${pkg_dir}/node_modules/hermes-live-voice/plugins/hermes-live"
  [ -f "${plugin_src}/plugin.yaml" ] \
    || error "hermes-live-voice did not ship the Hermes plugin (plugins/hermes-live/plugin.yaml)"

  status "Installing the hermes-live dashboard plugin into .hermes/plugins"
  mkdir -p "${build_dir}/.hermes/plugins"
  rm -rf "${build_dir}/.hermes/plugins/hermes-live"
  cp -a "${plugin_src}" "${build_dir}/.hermes/plugins/hermes-live"
  find "${build_dir}/.hermes/plugins/hermes-live" -type d -name '__pycache__' -prune -exec rm -rf '{}' +
  find "${build_dir}/.hermes/plugins/hermes-live" -type f -name '*.pyc' -delete

  status "Installing plugin Python dependencies (fastapi, httpx, websockets)"
  bp_ensure_uv
  "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" \
    'fastapi>=0.100,<1' 'httpx>=0.27,<1' 'websockets>=15,<16'

  status "Enabling the hermes-live plugin in .hermes/config.yaml"
  mkdir -p "${build_dir}/.hermes"
  touch "${build_dir}/.hermes/config.yaml"
  if grep -q '^plugins:' "${build_dir}/.hermes/config.yaml"; then
    error ".hermes/config.yaml already has a plugins: section; add 'hermes-live' to plugins.enabled manually"
  fi
  printf 'plugins:\n  enabled:\n    - hermes-live\n' >> "${build_dir}/.hermes/config.yaml"
}
