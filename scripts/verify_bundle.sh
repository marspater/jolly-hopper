#!/bin/bash
set -euo pipefail

echo "==> Running Siphon Bundle & Version Consistency Verification..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PBX_FILE="$PROJECT_ROOT/Siphon.xcodeproj/project.pbxproj"
INFO_PLIST="$PROJECT_ROOT/Siphon/Info.plist"

EXPECTED_MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")
EXPECTED_BUILD_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")

echo "--- Checking Version Consistency across Targets ---"
MARKETING_VERSIONS=$(grep 'MARKETING_VERSION =' "$PBX_FILE" | tr -d '\t; ' | sort -u)
CURRENT_VERSIONS=$(grep 'CURRENT_PROJECT_VERSION =' "$PBX_FILE" | tr -d '\t; ' | sort -u)

echo "Expected Marketing Version: $EXPECTED_MARKETING_VERSION"
echo "Discovered Marketing Versions:"
echo "$MARKETING_VERSIONS"

echo "Expected Build Version: $EXPECTED_BUILD_VERSION"
echo "Discovered Current Project Versions:"
echo "$CURRENT_VERSIONS"

if [[ "$MARKETING_VERSIONS" != "MARKETING_VERSION=$EXPECTED_MARKETING_VERSION" ]]; then
    echo "ERROR: project.pbxproj marketing versions do not match Info.plist ($EXPECTED_MARKETING_VERSION)" >&2
    exit 1
fi

if [[ "$CURRENT_VERSIONS" != "CURRENT_PROJECT_VERSION=$EXPECTED_BUILD_VERSION" ]]; then
    echo "ERROR: project.pbxproj build versions do not match Info.plist ($EXPECTED_BUILD_VERSION)" >&2
    exit 1
fi

echo "--- Version Consistency Check Passed! ---"
