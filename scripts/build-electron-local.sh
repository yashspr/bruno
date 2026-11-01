#!/bin/bash
#
# Build an unsigned, personal macOS build of this Bruno fork.
#
# Mirrors scripts/build-electron.sh but uses electron-builder-config.local.js
# (no Apple Developer identity / no notarization) and ad-hoc signs the result,
# which macOS requires on Apple Silicon.
#
# Usage:
#   npm run build:web            # build the renderer first
#   ./scripts/build-electron-local.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -d packages/bruno-app/dist ]; then
  echo "error: packages/bruno-app/dist not found — run 'npm run build:web' first" >&2
  exit 1
fi

echo "==> Preparing web assets"
rm -rf packages/bruno-electron/out
rm -rf packages/bruno-electron/web
mkdir packages/bruno-electron/web
cp -r packages/bruno-app/dist/* packages/bruno-electron/web

# Rewrite absolute asset paths to relative (file:// loading in Electron)
sed -i'' -e 's@/static/@static/@g' packages/bruno-electron/web/**.html
sed -i'' -e 's@/static/font@../../static/font@g' packages/bruno-electron/web/static/css/**.**.css

# Drop sourcemaps
find packages/bruno-electron/web -name '*.map' -type f -delete

echo "==> Packaging (electron-builder, unsigned)"
npm run dist:mac:local --workspace=packages/bruno-electron

APP="$(find packages/bruno-electron/out -maxdepth 2 -name 'Bruno.app' -print -quit)"
if [ -z "$APP" ]; then
  echo "error: Bruno.app not found under packages/bruno-electron/out" >&2
  exit 1
fi

echo "==> Ad-hoc signing $APP"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature OK"

echo
echo "Build complete:"
echo "  app: $ROOT/$APP"
find "$ROOT/packages/bruno-electron/out" -maxdepth 1 -name '*.dmg' -exec echo "  dmg: {}" \;
echo
echo "To install:"
echo "  rm -rf /Applications/Bruno.app && cp -R \"$ROOT/$APP\" /Applications/"
