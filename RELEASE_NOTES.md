# InfraProxy 2.6.0

- Introduces a VibeTunnel-inspired menu panel with provider status, local activity, quick actions, and System/Light/Dark themes. Right-click retains advanced controls.
- Discovers Tailscale status, hostname, device addresses, and online/offline state.
- Adds private Tailscale Serve, public Tailscale Funnel, and Cloudflare Quick Tunnel controls for local web applications, with explicit sharing confirmation and Open/Copy/Stop actions.
- Preserves existing provider configuration and manages only tunnels started by InfraProxy.

- Adds **Check for Updates…** to the menu bar and an **Updates** tab in the dashboard.
- Checks for new releases daily by default, with a toggle to disable automatic checks. Users choose when to install; installation restarts InfraProxy.
- Uses Sparkle 2.10.0 to download, verify, install, and relaunch updates. Both the update feed and archive are signed with InfraProxy's Ed25519 key; application and DMG releases are Developer ID signed and notarized.
- Explicitly targets macOS 15.5 so the binary matches the documented minimum OS.
- Adds a reproducible packaging script that generates and verifies the update feed with each release.
- Retains the Teleport timer, connection dashboard, Google browser sign-in, automatic account/project discovery, and cloud resource browsing from v2.5.0.

## Updating

Install v2.6.0 once to enable in-app updates; earlier releases do not contain an updater. Afterward, use **Check for Updates…** from the menu bar or open **Dashboard → Updates**. InfraProxy will also notify you when its daily check finds a newer release.

Google Cloud CLI remains required for cloud integration. Update installation restarts the app, so choose a suitable time during active operations.

Tailscale and cloudflared are separately installed tools. Serve/Funnel use HTTPS port 8443 and require provider permissions. Cloudflare Quick Tunnel setup refuses existing config files. Public links require authentication in the shared web application. This release does not add a browser terminal.
