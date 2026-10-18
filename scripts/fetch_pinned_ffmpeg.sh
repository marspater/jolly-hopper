#!/bin/bash
# Downloads the FFmpeg/FFprobe build pinned in DependencyChecksums for this
# Mac's architecture into DEST, verifying archive and executable SHA-256 pins.
# Usage: scripts/fetch_pinned_ffmpeg.sh DEST
set -euo pipefail

dest=${1:?usage: fetch_pinned_ffmpeg.sh DEST}
root=$(cd "$(dirname "$0")/.." && pwd)
source_file="$root/Siphon/Services/Download/YtdlpService.swift"

case "$(uname -m)" in
  arm64) branch='/#if arch\(arm64\)/{f=1;next} f&&/#else/{exit} f' ;;
  x86_64) branch='/#if arch\(arm64\)/{s=1} s&&/#else/{f=1;next} f&&/#endif/{exit} f' ;;
  *) echo "Unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
# The first arch block in the file is DependencyChecksums.
pins=$(awk "$branch" "$source_file")

pin() {
  local value
  value=$(printf '%s\n' "$pins" | sed -nE "s/.*static let $1 = \"([0-9a-f]{64})\".*/\1/p")
  [[ -n "$value" ]] || { echo "No pin for $1" >&2; exit 1; }
  printf '%s' "$value"
}

mkdir -p "$dest"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for tool in ffmpeg ffprobe; do
  read -r arch build < <(printf '%s\n' "$pins" |
    sed -nE "s/.*static let ${tool}URL = ffmpegBuildURL\(architecture: \"([^\"]+)\", build: \"([^\"]+)\", tool: \"$tool\"\).*/\1 \2/p")
  [[ -n "${build:-}" ]] || { echo "No pinned URL for $tool" >&2; exit 1; }
  curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    -o "$work/$tool.zip" "https://ffmpeg.martin-riedl.de/download/macos/$arch/$build/$tool.zip"
  echo "$(pin "${tool}ArchiveSHA256")  $work/$tool.zip" | shasum -a 256 -c -
  unzip -q -o "$work/$tool.zip" "$tool" -d "$work"
  echo "$(pin "${tool}ExecutableSHA256")  $work/$tool" | shasum -a 256 -c -
  install -m 0755 "$work/$tool" "$dest/$tool"
done
