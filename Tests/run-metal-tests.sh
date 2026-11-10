#!/bin/zsh
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
/usr/bin/xcrun swift "$repo_dir/Tests/MetalShaderTests.swift" "$repo_dir/色々変え/ColorShaders.metal"
