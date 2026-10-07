# InfraProxy 2.6.0

- Adds **Check for Updates…** to the menu bar and an **Updates** tab in the dashboard.
- Checks for new releases daily by default, with a toggle to disable automatic checks. Users choose when to install; installation restarts InfraProxy.
- Uses Sparkle 2.10.0 to download, verify, install, and relaunch updates. Both the update feed and archive are signed with InfraProxy's Ed25519 key; application and DMG releases are Developer ID signed and notarized.
- Explicitly targets macOS 15.5 so the binary matches the documented minimum OS.
- Adds a reproducible packaging script that generates and verifies the update feed with each release.
- Retains the Teleport timer, connection dashboard, Google browser sign-in, automatic account/project discovery, and cloud resource browsing from v2.5.0.

## Updating

Install v2.6.0 once to enable in-app updates; earlier releases do not contain an updater. Afterward, use **Check for Updates…** from the menu bar or open **Connection Dashboard & GCP → Updates**. InfraProxy will also notify you when its daily check finds a newer release.

Google Cloud CLI remains required for cloud integration. Update installation restarts the app, so choose a suitable time during active operations.
