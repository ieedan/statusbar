#!/usr/bin/env bash
#
# Wraps a built StatusBar.app in a drag-to-Applications disk image.
#
#   scripts/build-dmg.sh <StatusBar.app> <output.dmg>
#
# The window layout (size, icon positions, arrow background) comes from
# scripts/dmg-settings.py via `dmgbuild`, which writes the layout directly instead of
# scripting Finder, so it works headless on CI. dmgbuild is installed into a private
# virtualenv on first use.
#
# Signing and notarizing the .dmg is the caller's job (see release.yml).
#
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <StatusBar.app> <output.dmg>" >&2
  exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT="$2"
VOLUME_NAME="StatusBar"
DMGBUILD_VERSION="1.6.5"
VENV="$ROOT/.build/dmgbuild-venv"

[ -d "$APP" ] || { echo "error: $APP not found — run 'make app' first" >&2; exit 1; }

if [ ! -x "$VENV/bin/dmgbuild" ]; then
  echo "› Installing dmgbuild…"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "dmgbuild==$DMGBUILD_VERSION"
fi

echo "› Creating $(basename "$OUT")…"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
"$VENV/bin/dmgbuild" -s "$ROOT/scripts/dmg-settings.py" -D "app=$APP" -D "root=$ROOT" "$VOLUME_NAME" "$OUT"

echo "✓ Built $OUT"
