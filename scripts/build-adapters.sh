#!/usr/bin/env bash
#
# Installs adapter deps (first run) and compiles every TypeScript adapter to a
# self-contained JS bundle under adapters/<id>/dist/.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/adapters"

if [ ! -d node_modules ]; then
  echo "› Installing adapter dependencies…"
  pnpm install
fi

echo "› Building adapters…"
pnpm build
