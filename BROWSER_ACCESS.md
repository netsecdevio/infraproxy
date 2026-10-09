# Standalone browser access

Start Dashboard in the Mac app, then open the local browser. Inbound settings can forward its loopback service through Tailscale, Cloudflare, or ngrok. The remote client uses the provider URL, not localhost. Sharing stays off until explicitly enabled.

## Authentication

Use the Mac app's rotating access key or an Ed25519 challenge signed by a key authorized in the host user's ~/.ssh/authorized_keys. The browser can generate a private key locally and download its public key for the owner to add through normal SSH administration. The app does not edit authorized_keys. Only option-free Ed25519 entries are accepted; options are never ignored. Private keys remain client-side. Key-file changes invalidate human sessions at the next one-second refresh.

Agent access uses separate token hashes and expiring local grants. SPIFFE/SPIRE integration is deferred. Tokens and shell output must not be included in issue reports.

## Terminal restrictions

Every newly created terminal runs under a macOS sandbox profile with access to its selected approved workspace and private temporary home. Environment variables are replaced with a minimal allowlist. Network, host credential stores, and unrelated filesystem contents are denied. Some file metadata and system runtime files remain readable. The default workspace is ~/infravibe-workspace; additional project folders are approved locally in Dashboard. Choose narrow folders: all contents of the selected workspace are accessible to that session.

No existing host tmux attachment, unrestricted shell fallback, or networking elevation is provided in this release. If sandbox setup fails, the session fails rather than running unrestricted. macOS sandbox-exec is a platform dependency; future OS compatibility must be tested.

Disconnecting a browser leaves its terminal running, bounded to eight hours. End session or stop the server to terminate the PTY. Detached descendants may outlive the shell, but inherit its sandbox. Revocation cannot undo files already changed or credentials already disclosed.

## Retained data

Exited sessions store bounded output (256 KiB each, at most 100 sessions) under the user's application-support directory with restrictive filesystem permissions. This history is not application-encrypted. Use Clear exited to remove saved history. Session notification contents exclude commands, directories, and output.
