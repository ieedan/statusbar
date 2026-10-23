#!/usr/bin/env bash
#
# Wraps a built StatusBar.app in a drag-to-Applications disk image.
#
#   scripts/build-dmg.sh <StatusBar.app> <output.dmg>
#
# Signing and notarizing the .dmg is the caller's job (see release.yml).
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <StatusBar.app> <output.dmg>" >&2
  exit 64
fi

APP="$1"
OUT="$2"
VOLUME_NAME="StatusBar"

[ -d "$APP" ] || { echo "error: $APP not found — run 'make app' first" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

echo "› Staging disk image contents…"
# ditto keeps the code signature and any stapled notarization ticket intact.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

echo "› Creating $(basename "$OUT")…"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -ov "$OUT" >/dev/null

echo "✓ Built $OUT"
