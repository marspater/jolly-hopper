#!/bin/bash
set -euo pipefail

# Keep a signed local identity: unsigned test builds must never replace the installed app.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/local-signed"
MODE="${1:---run}"
case "$MODE" in
    --run|--verify|--build) ;;
    *) echo "Usage: $0 [--run|--verify|--build]" >&2; exit 2 ;;
esac

xcodebuild build -project "$ROOT_DIR/Siphon.xcodeproj" -scheme Siphon \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR" \
    MACOSX_DEPLOYMENT_TARGET=15.0 ENABLE_DEBUG_DYLIB=NO CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
APP="$BUILD_DIR/Build/Products/Debug/Siphon.app"
codesign --verify --deep --strict "$APP"
if [[ "$MODE" != --build ]]; then
    # SIGTERM allows normal shutdown; no forced kill and no user data is removed.
    if pgrep -x Siphon >/dev/null; then pkill -TERM -x Siphon; fi
    open -n "$APP"
    if [[ "$MODE" == --verify ]]; then
        pgrep -x Siphon >/dev/null
    fi
fi
