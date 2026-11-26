# bp_build_web_dist — builds the Hermes web dashboard (hermes_cli/web_dist)
# from the shipped source checkout. The SPA assets are NOT in the git checkout:
# they are produced by the "web" product build (scripts/build/web.mjs), which
# needs the workspace node dependencies installed with the pinned pnpm.
# node/npm come from .apt (see lib/apt.sh, APT_PACKAGES includes nodejs).
bp_build_web_dist() {
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
