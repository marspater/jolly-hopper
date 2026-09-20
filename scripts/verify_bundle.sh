#!/bin/bash
set -euo pipefail

echo "==> Running Siphon Bundle & Version Consistency Verification..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PBX_FILE="$PROJECT_ROOT/Siphon.xcodeproj/project.pbxproj"

# 1. Verify version consistency in project.pbxproj
echo "--- Checking Version Consistency across Targets ---"
MARKETING_VERSIONS=$(grep 'MARKETING_VERSION =' "$PBX_FILE" | tr -d '\t; ' | sort -u)
CURRENT_VERSIONS=$(grep 'CURRENT_PROJECT_VERSION =' "$PBX_FILE" | tr -d '\t; ' | sort -u)

echo "Discovered Marketing Versions:"
echo "$MARKETING_VERSIONS"

echo "Discovered Current Project Versions:"
echo "$CURRENT_VERSIONS"

# Ensure primary version 5.3.0 and build 53 are set
if ! grep -q 'MARKETING_VERSION = 5.3.0;' "$PBX_FILE"; then
    echo "ERROR: MARKETING_VERSION 5.3.0 not found in project.pbxproj" >&2
    exit 1
fi

if ! grep -q 'CURRENT_PROJECT_VERSION = 53;' "$PBX_FILE"; then
    echo "ERROR: CURRENT_PROJECT_VERSION 53 not found in project.pbxproj" >&2
    exit 1
fi

echo "--- Version Consistency Check Passed! ---"
