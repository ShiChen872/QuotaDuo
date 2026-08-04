#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-debug}"
# Allow `./script/build_and_run.sh --run`
if [[ "$CONFIGURATION" == "--run" ]]; then
  CONFIGURATION="debug"
  set -- debug --run
fi

PRODUCT_DIR="$ROOT/.build/$CONFIGURATION"
STAGING_APP="$ROOT/.build/QuotaDuo.app"
INSTALL_DIR="${HOME}/Applications"
INSTALLED_APP="$INSTALL_DIR/QuotaDuo.app"
CONTENTS="$STAGING_APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> swift build ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BIN="$PRODUCT_DIR/QuotaDuo"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> assemble $STAGING_APP"
rm -rf "$STAGING_APP"
mkdir -p "$MACOS_DIR"
mkdir -p "$CONTENTS/Resources"
cp "$BIN" "$MACOS_DIR/QuotaDuo"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
chmod +x "$MACOS_DIR/QuotaDuo"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$STAGING_APP" >/dev/null 2>&1 || true
fi

echo "==> install $INSTALLED_APP"
mkdir -p "$INSTALL_DIR"

# Quit any running instance before replacing the bundle.
if pgrep -x QuotaDuo >/dev/null 2>&1; then
  echo "==> quit running QuotaDuo"
  osascript -e 'tell application "QuotaDuo" to quit' >/dev/null 2>&1 || true
  # Wait briefly; force-kill if still alive.
  for _ in 1 2 3 4 5; do
    pgrep -x QuotaDuo >/dev/null 2>&1 || break
    sleep 0.3
  done
  if pgrep -x QuotaDuo >/dev/null 2>&1; then
    pkill -x QuotaDuo >/dev/null 2>&1 || true
    sleep 0.3
  fi
fi

rm -rf "$INSTALLED_APP"
cp -R "$STAGING_APP" "$INSTALLED_APP"
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$INSTALLED_APP" >/dev/null 2>&1 || true
fi

if [[ "${2:-}" == "--run" ]] || [[ "${1:-}" == "--run" ]]; then
  echo "==> launch $INSTALLED_APP"
  open "$INSTALLED_APP"
else
  echo "Installed: $INSTALLED_APP"
  echo "Run with: open \"$INSTALLED_APP\""
  echo "Or:       ./script/build_and_run.sh debug --run"
fi
