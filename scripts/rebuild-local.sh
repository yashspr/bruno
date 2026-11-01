#!/bin/bash
#
# Rebuild this Bruno fork and update the locally installed macOS app.
#
# Typical use, after syncing the fork and pulling:
#
#     git pull
#     ./scripts/rebuild-local.sh
#
# Flags:
#   --build-only   build + package, but don't touch /Applications
#   --clean        wipe node_modules and reinstall from scratch (like `npm run setup`)
#   --skip-deps    don't even check dependencies (fastest; use if nothing changed)
#
# Why this exists instead of `npm run setup && npm run build:web && ...`:
#
#   1. `npm run setup` ALWAYS deletes every node_modules directory and does a full
#      reinstall (~1.3 GB, several minutes). This script only reinstalls when
#      package-lock.json is actually newer than node_modules.
#
#   2. Building bruno-converters HANGS FOREVER. @rollup/plugin-terser keeps worker
#      threads alive, so `rollup -c` never exits even though the bundles are already
#      written. `npm run setup` therefore never completes. Every package build here
#      runs under a watchdog that detects the process going idle (CPU time flatlining,
#      NOT wall clock) and moves on.
#
#   3. Packaging needs Bruno's Apple signing identity stripped, and Apple Silicon
#      refuses to launch unsigned binaries — handled by build-electron-local.sh.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BUILD_ONLY=0
CLEAN=0
SKIP_DEPS=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --clean)      CLEAN=1 ;;
    --skip-deps)  SKIP_DEPS=1 ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

LOGDIR="$(mktemp -d -t bruno-rebuild)"
step()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()    { printf '    \033[32m%s\033[0m\n' "$1"; }
warn()  { printf '    \033[33m%s\033[0m\n' "$1"; }
fail()  { printf '    \033[31m%s\033[0m\n' "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Run a build step, giving up once it goes idle.
#
# rollup+terser never exits; the bundles are done long before. Poll cumulative
# CPU time of the process group — if it stops advancing, the work is finished
# and only the lingering process remains, so kill it and carry on.
# ---------------------------------------------------------------------------
IDLE_LIMIT=25
MAX_WALL=900
run_guarded() {
  local label="$1"; shift
  local log="$LOGDIR/$label.log"
  printf '    %-22s' "$label"
  "$@" > "$log" 2>&1 &
  local pid=$! last=-1 idle=0 waited=0 pgid
  pgid="$(ps -o pgid= -p $pid 2>/dev/null | tr -d ' ')"

  while kill -0 "$pid" 2>/dev/null; do
    sleep 3; waited=$((waited+3))
    local cpu
    cpu=$(ps -o time= -g "$pgid" 2>/dev/null | awk -F: '{s+=$1*60+$2} END {print int(s)}')
    cpu=${cpu:-0}
    if [ "$cpu" = "$last" ]; then idle=$((idle+3)); else idle=0; last=$cpu; fi

    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
      pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      echo "done (${waited}s, exit-hang bypassed)"
      return 0
    fi
    if [ "$waited" -ge "$MAX_WALL" ]; then
      pkill -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null
      echo "TIMEOUT"; echo "    see $log"; return 1
    fi
  done
  wait "$pid"; local rc=$?
  if [ $rc -ne 0 ]; then echo "FAILED (rc=$rc)"; echo "    see $log"; return $rc; fi
  echo "done (${waited}s)"
  return 0
}

# ---------------------------------------------------------------------------
step "Dependencies"
if [ "$CLEAN" = "1" ]; then
  warn "clean build — removing all node_modules"
  find . -name node_modules -type d -prune -not -path "./.git/*" -exec rm -rf {} + 2>/dev/null
  run_guarded "npm-install" npm i --legacy-peer-deps || fail "install failed"
  run_guarded "platform-deps" npm i --legacy-peer-deps --no-save --force \
    @lydell/node-pty-darwin-arm64@1.1.0 @lydell/node-pty-darwin-x64@1.1.0 || warn "platform deps failed"
elif [ "$SKIP_DEPS" = "1" ]; then
  ok "skipped (--skip-deps)"
elif [ ! -d node_modules ]; then
  warn "node_modules missing — installing"
  run_guarded "npm-install" npm i --legacy-peer-deps || fail "install failed"
  run_guarded "platform-deps" npm i --legacy-peer-deps --no-save --force \
    @lydell/node-pty-darwin-arm64@1.1.0 @lydell/node-pty-darwin-x64@1.1.0 || warn "platform deps failed"
elif [ package-lock.json -nt node_modules ]; then
  warn "package-lock.json changed — reinstalling"
  run_guarded "npm-install" npm i --legacy-peer-deps || fail "install failed"
else
  ok "up to date (no reinstall needed)"
fi

# ---------------------------------------------------------------------------
step "Workspace packages"
run_guarded "graphql-docs"    npm run build:graphql-docs     || fail "graphql-docs failed"
run_guarded "bruno-query"     npm run build:bruno-query      || fail "bruno-query failed"
run_guarded "bruno-common"    npm run build:bruno-common     || fail "bruno-common failed"
run_guarded "bruno-converters" npm run build:bruno-converters || fail "bruno-converters failed"
run_guarded "bruno-requests"  npm run build:bruno-requests   || fail "bruno-requests failed"
run_guarded "schema-types"    npm run build:schema-types     || fail "schema-types failed"
run_guarded "bruno-filestore" npm run build:bruno-filestore  || fail "bruno-filestore failed"
run_guarded "bruno-sqlite"    npm run build:bruno-sqlite     || fail "bruno-sqlite failed"
run_guarded "sandbox-libs"    npm run sandbox:bundle-libraries --workspace=packages/bruno-js \
  || fail "sandbox libraries failed"

# The watchdog kills processes rather than waiting for a clean exit, so confirm
# each package actually produced its entry point.
for p in bruno-common bruno-query bruno-converters bruno-requests bruno-filestore; do
  [ -f "packages/$p/dist/cjs/index.js" ] || fail "$p produced no dist/cjs/index.js"
done
[ -f "packages/bruno-sqlite/dist/node/cjs/index.js" ] || fail "bruno-sqlite produced no dist/node/cjs/index.js"
ok "all package outputs present"

# ---------------------------------------------------------------------------
step "Renderer"
run_guarded "bruno-app" npm run build:web || fail "renderer build failed"
[ -d packages/bruno-app/dist ] || fail "packages/bruno-app/dist missing"
ok "$(du -sh packages/bruno-app/dist | cut -f1) built"

# ---------------------------------------------------------------------------
step "Packaging macOS app"
./scripts/build-electron-local.sh > "$LOGDIR/package.log" 2>&1 \
  || { tail -25 "$LOGDIR/package.log"; fail "packaging failed (see $LOGDIR/package.log)"; }
APP="$(find packages/bruno-electron/out -maxdepth 2 -name 'Bruno.app' -print -quit)"
[ -n "$APP" ] || fail "Bruno.app not produced"
ok "$APP"

# ---------------------------------------------------------------------------
# Regression guard: the whole point of the fork is that the proprietary
# workspace limit isn't there. Fail loudly if a future upstream merge adds it.
step "Verifying no workspace limit"
ASAR="$APP/Contents/Resources/app.asar"
LIMIT=0
for s in "Workspace Limit Reached" "you can only have" "workspaces open at a time"; do
  n=$(grep -ac "$s" "$ASAR" 2>/dev/null || true)
  [ "${n:-0}" != "0" ] && { warn "FOUND '$s' ($n)"; LIMIT=1; }
done
# control string, proves the scan actually reads the archive
c=$(grep -ac "opencollection" "$ASAR" 2>/dev/null || true)
[ "${c:-0}" = "0" ] && fail "control string missing — verification unreliable"
if [ "$LIMIT" = "1" ]; then
  warn "a workspace limit appears to be present in this build!"
else
  ok "no limit strings (control 'opencollection': $c hits)"
fi

# ---------------------------------------------------------------------------
if [ "$BUILD_ONLY" = "1" ]; then
  step "Done (--build-only)"
  echo "    app: $ROOT/$APP"
  exit 0
fi

step "Installing to /Applications"
if pgrep -x Bruno >/dev/null; then
  warn "Bruno is running — quitting it"
  osascript -e 'quit app "Bruno"' 2>/dev/null
  for _ in $(seq 1 15); do pgrep -x Bruno >/dev/null || break; sleep 1; done
  pgrep -x Bruno >/dev/null && { pkill -x Bruno; sleep 2; }
fi

if [ -d /Applications/Bruno.app ]; then
  # Is the installed copy one of ours? Prefer the marker file we drop on install;
  # fall back to checking for an ad-hoc signature.
  #
  # NOTE: capture codesign's output into a variable rather than piping it into
  # `grep -q`. `grep -q` exits the moment it matches, codesign then takes SIGPIPE
  # (exit 141), and under `set -o pipefail` the pipeline reports failure even
  # though the match succeeded — a race that silently Trashes a 400 MB app.
  IS_LOCAL=0
  [ -f /Applications/Bruno.app/Contents/Resources/.local-build ] && IS_LOCAL=1
  if [ "$IS_LOCAL" = "0" ]; then
    SIGINFO="$(codesign -dv /Applications/Bruno.app 2>&1 || true)"
    case "$SIGINFO" in *"Signature=adhoc"*) IS_LOCAL=1 ;; esac
  fi

  if [ "$IS_LOCAL" = "1" ]; then
    rm -rf /Applications/Bruno.app
    ok "replaced previous local build"
  else
    T=~/.Trash/Bruno-replaced-$(date +%Y%m%d%H%M%S).app
    mv /Applications/Bruno.app "$T"
    warn "existing app was not a local build — moved to $T"
  fi
fi

cp -R "$APP" /Applications/Bruno.app
# Marker so future runs can identify this as a local build without parsing codesign.
date "+built %Y-%m-%d %H:%M:%S from $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  > /Applications/Bruno.app/Contents/Resources/.local-build
codesign --force --deep --sign - /Applications/Bruno.app >/dev/null 2>&1
codesign --verify --deep --strict /Applications/Bruno.app 2>/dev/null \
  && ok "installed and ad-hoc signed" || fail "signature verification failed"

VER=$(defaults read /Applications/Bruno.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
step "Done"
echo "    /Applications/Bruno.app  (version $VER)"
echo "    app data preserved at ~/Library/Application Support/bruno"
echo
echo "    launch with:  open -a Bruno"
echo
warn "On first launch macOS will ask for your login password to access the"
warn "'bruno Safe Storage' keychain item. Click \"Always Allow\"."
warn "This recurs after every rebuild: an ad-hoc signature is a hash of the"
warn "binary, so new bytes = new identity = the keychain ACL no longer matches."
warn "(Permanent fix would be signing with a stable self-signed certificate.)"
warn "Never delete that keychain item — it would make already-encrypted"
warn "secrets, cookies and OAuth2 tokens unrecoverable."
rm -rf "$LOGDIR"
