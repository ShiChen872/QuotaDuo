#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-debug}"
PRODUCT_DIR="$ROOT/.build/$CONFIGURATION"
APP_DIR="$ROOT/.build/QuotaDuo.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"

echo "==> swift build ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BIN="$PRODUCT_DIR/QuotaDuo"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> assemble $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN" "$MACOS_DIR/QuotaDuo"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
chmod +x "$MACOS_DIR/QuotaDuo"

# Ad-hoc sign so Gatekeeper is less noisy for local runs.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

if [[ "${2:-}" == "--run" ]] || [[ "${1:-}" == "--run" ]]; then
  echo "==> launch QuotaDuo"
  open "$APP_DIR"
else
  echo "Built: $APP_DIR"
  echo "Run with: open $APP_DIR"
  echo "Or:       ./script/build_and_run.sh debug --run"
fi
