#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build/release-signed}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/build/release-artifacts}"
RELEASE_TAG="${RELEASE_TAG:-}"
SIPHON_DEVELOPMENT_TEAM="${SIPHON_DEVELOPMENT_TEAM:-}"
DEVELOPER_IDENTITY="${DEVELOPER_IDENTITY:-}"
APPLE_NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
APPLE_NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
APPLE_NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"

require_value() {
    local name="$1"
    local value="$2"
    if [[ -z "$value" ]]; then
        echo "Missing required release credential/configuration: $name" >&2
        exit 2
    fi
}

require_value RELEASE_TAG "$RELEASE_TAG"
require_value SIPHON_DEVELOPMENT_TEAM "$SIPHON_DEVELOPMENT_TEAM"
require_value DEVELOPER_IDENTITY "$DEVELOPER_IDENTITY"
require_value APPLE_NOTARY_KEY_PATH "$APPLE_NOTARY_KEY_PATH"
require_value APPLE_NOTARY_KEY_ID "$APPLE_NOTARY_KEY_ID"
require_value APPLE_NOTARY_ISSUER_ID "$APPLE_NOTARY_ISSUER_ID"

if [[ ! -f "$APPLE_NOTARY_KEY_PATH" ]]; then
    echo "Notary API key does not exist at APPLE_NOTARY_KEY_PATH." >&2
    exit 2
fi

TAG_VERSION="${RELEASE_TAG#v}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/Siphon/Info.plist")"
if [[ "$TAG_VERSION" != "$PLIST_VERSION" ]]; then
    echo "Release tag $RELEASE_TAG does not match CFBundleShortVersionString $PLIST_VERSION." >&2
    exit 2
fi

rm -rf "$BUILD_DIR" "$ARTIFACT_DIR"
mkdir -p "$BUILD_DIR" "$ARTIFACT_DIR"

echo "Building Release with Developer ID identity..."
xcodebuild build \
    -project "$ROOT_DIR/Siphon.xcodeproj" \
    -scheme Siphon \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$BUILD_DIR" \
    MACOSX_DEPLOYMENT_TARGET=15.0 \
    SIPHON_DEVELOPMENT_TEAM="$SIPHON_DEVELOPMENT_TEAM" \
    DEVELOPMENT_TEAM="$SIPHON_DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="$DEVELOPER_IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

APP="$BUILD_DIR/Build/Products/Release/Siphon.app"
if [[ ! -d "$APP" ]]; then
    echo "Release build did not produce Siphon.app." >&2
    exit 1
fi

echo "Verifying Developer ID signature..."
codesign --verify --deep --strict --verbose=2 "$APP"
SIGNING_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
ACTUAL_TEAM_ID="$(printf '%s\n' "$SIGNING_INFO" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ "$ACTUAL_TEAM_ID" != "$SIPHON_DEVELOPMENT_TEAM" ]]; then
    echo "Signed app TeamIdentifier mismatch: expected $SIPHON_DEVELOPMENT_TEAM, got ${ACTUAL_TEAM_ID:-none}." >&2
    exit 1
fi
if ! printf '%s\n' "$SIGNING_INFO" | grep -q 'Authority=Developer ID Application'; then
    echo "Release app is not signed with a Developer ID Application certificate." >&2
    exit 1
fi

HELPER="$APP/Contents/Helpers/siphon-pgrp"
if [[ ! -x "$HELPER" ]]; then
    echo "Signed release is missing the native process-group helper." >&2
    exit 1
fi
codesign --verify --strict --verbose=2 "$HELPER"
HELPER_SIGNING_INFO="$(codesign -dv --verbose=4 "$HELPER" 2>&1)"
HELPER_TEAM_ID="$(printf '%s\n' "$HELPER_SIGNING_INFO" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
if [[ "$HELPER_TEAM_ID" != "$SIPHON_DEVELOPMENT_TEAM" ]]; then
    echo "Helper TeamIdentifier mismatch: expected $SIPHON_DEVELOPMENT_TEAM, got ${HELPER_TEAM_ID:-none}." >&2
    exit 1
fi
if ! printf '%s\n' "$HELPER_SIGNING_INFO" | grep -q 'runtime'; then
    echo "Embedded helper is missing the Hardened Runtime signing flag." >&2
    exit 1
fi

NOTARY_ZIP="$BUILD_DIR/Siphon-notary.zip"
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"

echo "Submitting app for notarization..."
xcrun notarytool submit "$NOTARY_ZIP" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

FINAL_ZIP="$ARTIFACT_DIR/Siphon-$RELEASE_TAG.zip"
ditto -c -k --keepParent "$APP" "$FINAL_ZIP"

DMG_ROOT="$BUILD_DIR/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Siphon.app"
ln -s /Applications "$DMG_ROOT/Applications"

FINAL_DMG="$ARTIFACT_DIR/Siphon-$RELEASE_TAG.dmg"
hdiutil create \
    -volname "Siphon" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$FINAL_DMG"

codesign --force --sign "$DEVELOPER_IDENTITY" --timestamp "$FINAL_DMG"
codesign --verify --verbose=2 "$FINAL_DMG"

echo "Submitting DMG for notarization..."
xcrun notarytool submit "$FINAL_DMG" \
    --key "$APPLE_NOTARY_KEY_PATH" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait

xcrun stapler staple "$FINAL_DMG"
xcrun stapler validate "$FINAL_DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$FINAL_DMG"

(
    cd "$ARTIFACT_DIR"
    shasum -a 256 "$(basename "$FINAL_DMG")" "$(basename "$FINAL_ZIP")" > SHA256SUMS.txt
)

echo "Signed and notarized release artifacts:"
ls -lh "$ARTIFACT_DIR"
cat "$ARTIFACT_DIR/SHA256SUMS.txt"
