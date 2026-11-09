#!/bin/bash
set -euo pipefail

# Siphon/Info.plist takes its versions from these build settings, so every
# target that sets one must agree. Targets may also leave them unset.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$SCRIPT_DIR/../Siphon.xcodeproj"
PBX_FILE="$PROJECT/project.pbxproj"

# The app itself must resolve both settings in every configuration it ships from.
for configuration in Debug Release TestDebug TestRelease; do
    settings=$(xcodebuild -showBuildSettings -project "$PROJECT" -target Siphon -configuration "$configuration")
    for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
        if ! grep -Eq "^[[:space:]]*$key = [^[:space:]]+" <<<"$settings"; then
            echo "ERROR: Siphon $configuration does not set $key" >&2
            exit 1
        fi
    done
done

for key in MARKETING_VERSION CURRENT_PROJECT_VERSION; do
    values=$(grep "[[:space:]]$key = " "$PBX_FILE" | sed -E "s/.*$key = \"?([^\";]*)\"?;.*/\1/" | sort -u)
    if [[ $(grep -c . <<<"$values") -ne 1 ]]; then
        echo "ERROR: expected one $key across targets, found: ${values:-none}" >&2
        exit 1
    fi
    echo "$key=$values"
done
