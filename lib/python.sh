# bp_ensure_uv — installs uv into CACHE_DIR (kept between builds); sets UV_BIN
bp_ensure_uv() {
  export UV_INSTALL_DIR="${CACHE_DIR}/uv"
  export UV_CACHE_DIR="${CACHE_DIR}/uv-cache"
  if [ ! -x "${UV_INSTALL_DIR}/uv" ]; then
    status "Installing uv ${UV_VERSION} (cached)"
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | sh
  fi
  UV_BIN="${UV_INSTALL_DIR}/uv"
}

# bp_setup_python BUILD_DIR — creates BUILD_DIR/.venv with Python $PYTHON_VERSION; sets VENV_DIR
# The venv is always created with `uv venv --seed`: `python -m venv` needs
# ensurepip (the python3.X-venv package), which stack base images often lack,
# while uv seeds pip itself without ensurepip. scalingo-26 ships python3.14 in
# the base image; on older stacks we fall back to a uv-managed interpreter kept
# in CACHE_DIR so rebuilds stay fast.
bp_setup_python() {
  local build_dir="$1"
  VENV_DIR="${build_dir}/.venv"
  bp_ensure_uv

  local py=""
  if command -v "python${PYTHON_VERSION}" >/dev/null 2>&1; then
    status "Using system python${PYTHON_VERSION}"
    py="$(command -v "python${PYTHON_VERSION}")"
  else
    status "python${PYTHON_VERSION} not in the stack image, installing it with uv (cached)"
    "$UV_BIN" python install "${PYTHON_VERSION}"
    py="$("$UV_BIN" python find "${PYTHON_VERSION}")"
  fi

  "$UV_BIN" venv --seed --python "$py" "$VENV_DIR"

  # ctypes.util.find_library only consults the ldconfig cache / gcc / ld, so it
  # never sees libraries extracted into .apt (exposed via LD_LIBRARY_PATH by
  # .profile.d/000_apt.sh). That breaks e.g. the Discord voice codec probe
  # (plugins/platforms/discord/adapter_opus.py uses find_library("opus") and
  # would report "Opus codec not found"). Patch find_library to also scan
  # LD_LIBRARY_PATH, via a real module imported by a SINGLE-LINE .pth (multi-line
  # .pth files are not applied on Python 3.14, and a venv sitecustomize.py is
  # shadowed by Debian's /usr/lib/python3.14/sitecustomize.py).
  local site_packages
  site_packages="$(ls -d "${VENV_DIR}"/lib/python*/site-packages | head -n 1)"
  cat > "${site_packages}/bp_findlib_patch.py" <<'EOF'
import ctypes.util as _ctu
import glob as _glob
import os as _os

_bp_orig_find_library = _ctu.find_library

def _bp_find_library(name):
    lib = _bp_orig_find_library(name)
    if lib:
        return lib
    for d in _os.environ.get("LD_LIBRARY_PATH", "").split(_os.pathsep):
        if not d:
            continue
        for pat in ("lib%s.so*" % name, "%s.so*" % name):
            for cand in sorted(_glob.glob(_os.path.join(d, pat))):
                return cand
    return None

_ctu.find_library = _bp_find_library
EOF
  printf 'import bp_findlib_patch\n' > "${site_packages}/zz_bp_findlib.pth"
}

# bp_install_hermes — installs hermes-agent's locked dependencies from the pinned
# git tag and ships the source checkout in the app.
# Hermes only supports source-checkout installs (its setup.py refuses to build
# wheels outside Nix, and wheels would miss bundled assets), so the checkout is
# copied into BUILD_DIR (it becomes /app at runtime) and made importable at
# runtime via PYTHONPATH=/app/hermes-src (see .profile.d/hermes.sh) plus the
# bin/hermes wrapper below. The project itself is NOT installed into the venv
# (--no-install-project): an editable install would record the build-time
# absolute path (/tmp/build_<hash>/...) in site-packages, which does not exist
# at runtime (/app). Upstream's pyproject also relies on [tool.uv]
# override-dependencies (e.g. Pillow), which only apply when uv syncs the
# project itself: a plain `pip install git+...@tag` fails to resolve.
# The clone is cached in CACHE_DIR and only re-fetched when the tag changes.
bp_install_hermes() {
  bp_ensure_uv
  local src_cache="${CACHE_DIR}/hermes-src"
  if [ ! -d "${src_cache}/.git" ] || [ "$(cat "${src_cache}/.bp-tag" 2>/dev/null)" != "${HERMES_AGENT_VERSION}" ]; then
    status "Fetching hermes-agent ${HERMES_AGENT_VERSION}"
    rm -rf "$src_cache"
    git clone --depth 1 --branch "${HERMES_AGENT_VERSION}" "${HERMES_AGENT_REPO}" "$src_cache"
    printf '%s' "${HERMES_AGENT_VERSION}" > "${src_cache}/.bp-tag"
  fi
  status "Shipping hermes-agent source in the app (runtime layout)"
  rm -rf "${BUILD_DIR}/hermes-src"
  cp -a "$src_cache" "${BUILD_DIR}/hermes-src"
  rm -rf "${BUILD_DIR}/hermes-src/.git"
  local extra_args=()
  local extra
  for extra in $(bp_env HERMES_UV_EXTRAS ""); do
    extra_args+=(--extra "$extra")
  done
  if [ ${#extra_args[@]} -gt 0 ]; then
    status "uv extras from HERMES_UV_EXTRAS: $(bp_env HERMES_UV_EXTRAS "")"
  fi
  status "Installing hermes-agent ${HERMES_AGENT_VERSION} dependencies (uv.lock, frozen)"
  (cd "${BUILD_DIR}/hermes-src" && UV_PROJECT_ENVIRONMENT="${VENV_DIR}" "$UV_BIN" sync --frozen --no-install-project "${extra_args[@]}" --python "${VENV_DIR}/bin/python")

  if [ -n "${HERMES_EXTRA_PACKAGES}" ]; then
    status "Installing extra packages: ${HERMES_EXTRA_PACKAGES}"
    "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" ${HERMES_EXTRA_PACKAGES}
  fi

  status "Writing bin/hermes wrappers"
  mkdir -p "${BUILD_DIR}/bin"
  cat > "${BUILD_DIR}/bin/hermes" <<'EOF'
#!/usr/bin/env bash
exec /app/.venv/bin/python -m hermes_cli.main "$@"
EOF
  cat > "${BUILD_DIR}/bin/hermes-agent" <<'EOF'
#!/usr/bin/env bash
exec /app/.venv/bin/python -c 'import sys; from agent.legacy_cli import main; sys.exit(main())' "$@"
EOF
  cat > "${BUILD_DIR}/bin/hermes-acp" <<'EOF'
#!/usr/bin/env bash
exec /app/.venv/bin/python -m acp_adapter.entry "$@"
EOF
  chmod +x "${BUILD_DIR}/bin/hermes" "${BUILD_DIR}/bin/hermes-agent" "${BUILD_DIR}/bin/hermes-acp"

  status "Rewriting venv console-script shebangs to the runtime path"
  local script
  for script in "${VENV_DIR}/bin"/*; do
    [ -f "$script" ] || continue
    head -c 2 "$script" 2>/dev/null | grep -q '#!' || continue
    sed -i "1s|^#!${BUILD_DIR}|#!/app|" "$script" 2>/dev/null || true
  done
}

# bp_write_hermes_config BUILD_DIR — bakes /app/.hermes/config.yaml at compile
# time from app env vars (exposed in ENV_DIR during the build). The container fs
# is ephemeral on Scalingo, so a config.yaml written at runtime would be lost on
# restart; and stt/tts/voice provider selection only exists as config.yaml keys
# (there is no env mapping for stt.provider/tts.provider), so we generate it at
# build time. Keys that DO have env mappings (API keys, HERMES_MODEL, …) still
# win at runtime via the environment / the .env bridge in .profile.d/hermes.sh.
bp_write_hermes_config() {
  local build_dir="$1"
  local stt_provider stt_language tts_provider tts_voice voice_auto_tts voice_auto_tts_mode
  stt_provider="$(bp_env HERMES_STT_PROVIDER "")"
  stt_language="$(bp_env HERMES_STT_LANGUAGE "")"
  tts_provider="$(bp_env HERMES_TTS_PROVIDER "")"
  tts_voice="$(bp_env HERMES_TTS_VOICE "")"
  voice_auto_tts="$(bp_env HERMES_VOICE_AUTO_TTS "")"
  voice_auto_tts_mode="$(bp_env HERMES_VOICE_AUTO_TTS_MODE "")"
  if [ -z "${stt_provider}${stt_language}${tts_provider}${tts_voice}${voice_auto_tts}${voice_auto_tts_mode}" ]; then
    return 0
  fi
  status "Writing .hermes/config.yaml from HERMES_STT_*/HERMES_TTS_*/HERMES_VOICE_* env vars"
  mkdir -p "${build_dir}/.hermes"
  {
    if [ -n "$stt_provider" ] || [ -n "$stt_language" ]; then
      echo "stt:"
      if [ -n "$stt_provider" ]; then printf '  provider: %s\n' "$stt_provider"; fi
      if [ -n "$stt_language" ]; then printf '  language: %s\n' "$stt_language"; fi
    fi
    if [ -n "$tts_provider" ] || [ -n "$tts_voice" ]; then
      echo "tts:"
      if [ -n "$tts_provider" ]; then printf '  provider: %s\n' "$tts_provider"; fi
      if [ -n "$tts_voice" ]; then printf '  edge:\n    voice: %s\n' "$tts_voice"; fi
    fi
    if [ -n "$voice_auto_tts" ] || [ -n "$voice_auto_tts_mode" ]; then
      echo "voice:"
      if [ -n "$voice_auto_tts" ]; then printf '  auto_tts: %s\n' "$voice_auto_tts"; fi
      if [ -n "$voice_auto_tts_mode" ]; then printf '  auto_tts_mode: %s\n' "$voice_auto_tts_mode"; fi
    fi
  } > "${build_dir}/.hermes/config.yaml"
}

# bp_install_app_requirements BUILD_DIR — installs the app's requirements.txt
# into the venv, excluding hermes-agent lines (the buildpack pins that version).
bp_install_app_requirements() {
  local build_dir="$1"
  [ -f "${build_dir}/requirements.txt" ] || return 0
  bp_ensure_uv
  status "Installing application requirements"
  grep -viE 'hermes[-_]agent' "${build_dir}/requirements.txt" > "${CACHE_DIR}/requirements.app.txt" || true
  if [ -s "${CACHE_DIR}/requirements.app.txt" ]; then
    "$UV_BIN" pip install --python "${VENV_DIR}/bin/python" -r "${CACHE_DIR}/requirements.app.txt"
  fi
}
