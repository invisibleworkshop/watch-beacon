#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "請先安裝 XcodeGen："
  echo "  brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "已產生 WatchGPSBridge.xcodeproj（Team VHX5NF3JWK、Automatic signing）。"
