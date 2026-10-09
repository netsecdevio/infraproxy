#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/fetch-sparkle.sh
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
TEST_ARCH=${TEST_ARCH:-$(uname -m)}
case "$TEST_ARCH" in arm64|x86_64) ;; *) echo "Unsupported TEST_ARCH" >&2; exit 1 ;; esac
swiftc -target "$TEST_ARCH-apple-macosx15.5" Sources/ProxyModels.swift Sources/LaunchctlServiceManager.swift \
  Sources/InfraProxyManager.swift Sources/InfraProxyActions.swift \
  Sources/DevOpsWorkspace.swift Sources/DevOpsConfiguration.swift Sources/DevOps.swift Sources/Operations.swift Sources/OperationsCommand.swift Sources/CloudOperations.swift Sources/AppUpdater.swift Sources/MenuBarPanel.swift Sources/RemoteAccess.swift Sources/AppSettings.swift Sources/BrowserKeys.swift Sources/AgentAccess.swift Sources/TerminalSession.swift Sources/BrowserServer.swift Sources/BrowserDashboard.swift Tests/main.swift \
  -framework Cocoa -framework UserNotifications \
  -F Vendor/Sparkle -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/Vendor/Sparkle" -o "$TEST_DIR/tests"
/usr/bin/arch "-$TEST_ARCH" "$TEST_DIR/tests"
