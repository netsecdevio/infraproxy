#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/fetch-sparkle.sh
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc -target "$(uname -m)-apple-macosx15.5" Sources/ProxyModels.swift Sources/LaunchctlServiceManager.swift \
  Sources/InfraProxyManager.swift Sources/InfraProxyActions.swift \
  Sources/Operations.swift Sources/OperationsCommand.swift Sources/CloudOperations.swift Sources/AppUpdater.swift Tests/main.swift \
  -framework Cocoa -framework UserNotifications \
  -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/Vendor/Sparkle" -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
