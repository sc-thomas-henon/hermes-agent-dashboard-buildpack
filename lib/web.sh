# bp_build_web_dist — builds the Hermes web dashboard (hermes_cli/web_dist)
# from the shipped source checkout. The SPA assets are NOT in the git checkout:
# they are produced by the "web" product build (scripts/build/web.mjs), which
# needs the workspace node dependencies installed with the pinned pnpm.
# node/npm come from the official standalone nodejs.org tarball (NODE_VERSION),
# cached in CACHE_DIR: the apt nodejs deb is unusable from .apt because Debian
# externalizes builtins to /usr/share/nodejs, missing at runtime (core dump).
# Node is only needed at build time; the dashboard serves prebuilt static assets.
bp_build_web_dist() {
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
  export PATH="${node_dir}/bin:${PATH}"
  node --version
  npm --version

  status "Building Hermes web dashboard (web_dist) with pnpm ${PNPM_VERSION}"
  npm install -g "pnpm@${PNPM_VERSION}"
  (
    cd "${BUILD_DIR}/hermes-src" \
    && pnpm install --frozen-lockfile --ignore-scripts --store-dir "${CACHE_DIR}/pnpm-store" \
    && node scripts/build/web.mjs
  )
  [ -f "${BUILD_DIR}/hermes-src/hermes_cli/web_dist/index.html" ] \
    || error "web dashboard build did not produce hermes_cli/web_dist/index.html"
  status "Web dashboard built"
}
