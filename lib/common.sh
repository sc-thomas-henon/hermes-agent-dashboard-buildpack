warn() {
  echo " !     $*" >&2
}

error() {
  echo " !     $*" >&2
  exit 1
}

status() {
  echo "-----> $*"
}

indent() {
  c='s/^/       /'
  case $(uname) in
    Darwin) sed -l "$c";;
    *)      sed -u "$c";;
  esac
}

# bp_env NAME DEFAULT
# On Scalingo the app config vars are not exported during the build, they are
# exposed as one file per variable in ENV_DIR.
bp_env() {
  local name="$1" default="$2"
  if [ -n "${ENV_DIR:-}" ] && [ -f "${ENV_DIR}/${name}" ]; then
    cat "${ENV_DIR}/${name}"
  else
    printf '%s' "$default"
  fi
}
