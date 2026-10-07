#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc Sources/ProxyModels.swift Sources/LaunchctlServiceManager.swift \
  Sources/InfraProxyManager.swift Sources/InfraProxyActions.swift \
  Sources/Operations.swift Sources/OperationsCommand.swift Sources/CloudOperations.swift Tests/main.swift \
  -framework Cocoa -framework UserNotifications -o "$TEST_DIR/tests"
"$TEST_DIR/tests"
