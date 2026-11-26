#!/usr/bin/env bash
set -e
set -o pipefail

BP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/cache" "$TMP/env"

echo "== bash -n on all scripts =="
for f in "$BP_DIR"/bin/detect "$BP_DIR"/bin/compile "$BP_DIR"/bin/release \
         "$BP_DIR"/lib/*.sh "$BP_DIR"/conf/*.sh "$BP_DIR"/test/run.sh; do
  bash -n "$f"
done
echo "OK"

echo "== detect on fixture app (expect match) =="
"$BP_DIR/bin/detect" "$BP_DIR/test/fixture-app"
echo "OK"

echo "== detect on empty app (expect exit 1) =="
mkdir -p "$TMP/empty-app"
if "$BP_DIR/bin/detect" "$TMP/empty-app"; then
  echo "FAIL: detect should have exited 1"
  exit 1
fi
echo "OK"

echo "== release YAML =="
cp -r "$BP_DIR/test/fixture-app" "$TMP/build"
"$BP_DIR/bin/release" "$TMP/build" | tee "$TMP/release.yaml"
grep -q "^default_process_types:" "$TMP/release.yaml"
grep -q "web: hermes dashboard" "$TMP/release.yaml"
echo "OK"

if [ "${1:-}" = "--compile" ]; then
  echo "== compile fixture app (needs root + network) =="
  "$BP_DIR/bin/compile" "$TMP/build" "$TMP/cache" "$TMP/env"
  "$TMP/build/.venv/bin/hermes" --version
  test -d "$TMP/build/hermes-src"
  test -f "$TMP/build/.profile.d/hermes.sh"
  echo "OK"
else
  echo "== compile skipped (pass --compile to run it, e.g. inside scalingo/scalingo-26) =="
fi

echo "ALL TESTS PASSED"
