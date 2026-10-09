# infravibe 2.8.0

InfraProxy is now infravibe, with the lowercase Cadence identity and a compact menu overview. Legacy bundle identifiers and the InfraProxy.app filename are retained for update compatibility.

- Reconnectable browser terminal sessions, live output previews, session sidebar, and bounded exited-session history.
- Standalone terminal sandbox: selected approved workspace access, isolated temporary home, no inherited credentials, and no network access. The default workspace is ~/infravibe-workspace. Approve additional repository folders locally in Dashboard.
- SSH challenge authentication reads the target Mac's ~/.ssh/authorized_keys. This release accepts option-free Ed25519 entries only; restricted entries and unsupported algorithms are rejected. Changes invalidate browser sessions on the next authorization refresh.
- Separate expiring agent tokens, local terminal-control approval, own-session authorization, revocation, and activity records through MCP.
- Native session start/end notification settings and sound controls. Command-level events are not yet supported.
- Homebrew cask renamed to infravibe with scoped trust instructions.

Terminal networking, attachment to existing host tmux sessions, native-terminal forwarding, the expanded command composer, and SPIFFE/SPIRE are not included. Network-enabled AI coding tools cannot run inside these restricted terminals yet. Provider tunnels remain available for inbound dashboard access and existing local web services.

All bundled executables are Universal2. The sandbox uses macOS sandbox-exec and fails closed if its executable or policy is unavailable; compatibility with unreleased macOS versions is not guaranteed. Authentication does not replace sandbox enforcement.

Use Check for Updates to install and relaunch. Updating ends active terminals. Exited history retains up to 100 sessions with 256 KiB output each; clear saved sessions to remove it. History is protected by filesystem permissions, not application-level encryption. Do not intentionally store credentials in terminal output.

Known update quirk: provider discovery may show Tailscale as unavailable immediately after Sparkle relaunch. Quit and reopen infravibe normally to refresh discovery. This workaround was verified; the underlying relaunch issue remains under investigation.
