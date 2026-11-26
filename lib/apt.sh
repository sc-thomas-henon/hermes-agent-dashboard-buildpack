# System packages are NOT installed system-wide: on Scalingo, bin/compile runs
# as a non-root user, so apt cannot write /var/lib/apt. We follow the official
# Scalingo apt-buildpack approach: redirect apt's state/cache/sources into the
# writable CACHE_DIR, download the .debs only (apt-get -d), and extract them
# with dpkg -x into BUILD_DIR/.apt (which becomes /app/.apt at runtime).
# A .profile.d script then exposes the extracted bin/lib dirs at runtime.

bp_install_system_packages() {
  local build_dir="$1"
  local aptfile_manifest
  aptfile_manifest="$(bp_env APT_FILE_MANIFEST "${build_dir}/Aptfile")"

  local apt_cache_dir="${CACHE_DIR}/apt/cache"
  local apt_state_dir="${CACHE_DIR}/apt/state"
  local apt_sources_dir="${CACHE_DIR}/apt/sources"
  local apt_sources="${apt_sources_dir}/sources.list"
  local apt_sourceparts="${apt_sources_dir}/sources.list.d"

  mkdir -p "${apt_cache_dir}/archives/partial" "${apt_state_dir}/lists/partial" \
           "${apt_sources_dir}" "${apt_sourceparts}"
  cat /etc/apt/sources.list > "$apt_sources" 2>/dev/null || true
  cp -R /etc/apt/sources.list.d/. "$apt_sourceparts" 2>/dev/null || true

  local apt_options=("-o" "debug::nolocking=true"
                     "-o" "dir::cache=${apt_cache_dir}"
                     "-o" "dir::state=${apt_state_dir}"
                     "-o" "dir::etc::sourcelist=${apt_sources}"
                     "-o" "dir::etc::sourceparts=${apt_sourceparts}")

  status "Updating apt package index (cached)"
  apt-get "${apt_options[@]}" update -qq

  local pkgs="${APT_PACKAGES}"
  if [ -f "$aptfile_manifest" ]; then
    status "Reading extra packages from ${aptfile_manifest}"
    pkgs="${pkgs} $(grep -vE '^\s*(#|$)' "$aptfile_manifest" | grep -v '^:repo:' | tr '\n' ' ')"
  fi

  status "Downloading system packages: ${pkgs}"
  DEBIAN_FRONTEND=noninteractive apt-get "${apt_options[@]}" -y -qq \
    -o APT::Install-Recommends=false -d install --reinstall $pkgs

  status "Extracting packages into .apt"
  rm -rf "${build_dir}/.apt"
  mkdir -p "${build_dir}/.apt"
  local deb
  for deb in "${apt_cache_dir}/archives/"*.deb; do
    [ -e "$deb" ] || continue
    dpkg -x "$deb" "${build_dir}/.apt/"
  done

  local apt_root="${build_dir}/.apt"
  export PATH="${apt_root}/usr/bin:${apt_root}/usr/sbin:${apt_root}/bin:${PATH}"
  export LD_LIBRARY_PATH="${apt_root}/lib/x86_64-linux-gnu:${apt_root}/usr/lib/x86_64-linux-gnu:${apt_root}/lib:${apt_root}/usr/lib:${LD_LIBRARY_PATH}"
  export LIBRARY_PATH="${apt_root}/lib/x86_64-linux-gnu:${apt_root}/usr/lib/x86_64-linux-gnu:${apt_root}/lib:${apt_root}/usr/lib:${LIBRARY_PATH}"
  export INCLUDE_PATH="${apt_root}/usr/include:${apt_root}/usr/include/x86_64-linux-gnu:${INCLUDE_PATH}"
  export CPATH="${INCLUDE_PATH}"
  export CPPPATH="${INCLUDE_PATH}"
  export PKG_CONFIG_PATH="${apt_root}/usr/lib/x86_64-linux-gnu/pkgconfig:${apt_root}/usr/lib/pkgconfig:${PKG_CONFIG_PATH}"

  status "Writing .profile.d/000_apt.sh"
  mkdir -p "${build_dir}/.profile.d"
  cat > "${build_dir}/.profile.d/000_apt.sh" <<'EOF'
export PATH="$HOME/.apt/usr/bin:$HOME/.apt/usr/sbin:$PATH"
export LD_LIBRARY_PATH="$HOME/.apt/lib/x86_64-linux-gnu:$HOME/.apt/usr/lib/x86_64-linux-gnu:$HOME/.apt/lib:$HOME/.apt/usr/lib:$LD_LIBRARY_PATH"
export LIBRARY_PATH="$HOME/.apt/lib/x86_64-linux-gnu:$HOME/.apt/usr/lib/x86_64-linux-gnu:$HOME/.apt/lib:$HOME/.apt/usr/lib:$LIBRARY_PATH"
export INCLUDE_PATH="$HOME/.apt/usr/include:$HOME/.apt/usr/include/x86_64-linux-gnu:$INCLUDE_PATH"
export CPATH="$INCLUDE_PATH"
export CPPPATH="$INCLUDE_PATH"
export PKG_CONFIG_PATH="$HOME/.apt/usr/lib/x86_64-linux-gnu/pkgconfig:$HOME/.apt/usr/lib/pkgconfig:$PKG_CONFIG_PATH"
EOF

  if [ -f "${apt_root}/usr/bin/git" ] && [ -d "${apt_root}/usr/lib/git-core" ]; then
    export GIT_EXEC_PATH="${apt_root}/usr/lib/git-core"
    echo 'export GIT_EXEC_PATH="$HOME/.apt/usr/lib/git-core"' >> "${build_dir}/.profile.d/000_apt.sh"
  fi

  find "${apt_root}" -type f -ipath '*/pkgconfig/*.pc' -print0 2>/dev/null \
    | xargs -0 --no-run-if-empty -n 1 sed -i -e "s!^prefix=.*\$!prefix=\$HOME/.apt!g" 2>/dev/null || true
}
