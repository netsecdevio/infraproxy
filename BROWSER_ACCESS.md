# Browser access

InfraProxy's browser server is an optional remote control surface for the Mac
user running the app. It is not a multi-user host or a sandbox. Anyone with a
valid access key can see connection metadata and run a shell with that user's
filesystem and network permissions. Share access only with trusted operators.

## Authentication and network boundary

- The server is off at launch and binds only to IPv4 loopback, default port 4021.
- Local browsers authenticate too. Open Browser supplies the current key in a
  URL fragment; the page clears the fragment immediately and submits the key.
- A 256-bit random access key exists only in app memory. It changes on server
  start and on Rotate key. Provider credentials remain with the provider CLI.
- Session cookies are HttpOnly, SameSite=Strict, expire after eight hours, and
  use Secure for HTTPS origins. Loopback HTTP intentionally omits Secure.
- Inbound providers terminate TLS and forward to loopback. Only localhost and
  currently ready provider hosts are accepted. Do not place an additional
  untrusted proxy in front of the server or rewrite its Host/Origin headers.
- Mutating requests and WebSocket upgrades require same-origin checks.
  WebSockets also require a single-use, 30-second ticket and a valid cookie.
- Login failures are rate limited globally (10 per minute). Connections,
  sessions, tickets, terminal count, request bodies, frames, and I/O queues are
  bounded. This limits resource use but does not promise public DoS resistance.
- Tailscale identity headers are not trusted as application authentication.
  Private tailnet policy adds protection; the app key is still required.

## Terminal lifecycle

Each browser terminal owns a native PTY helper and a login shell. Closing the
connection ends its shell; key rotation, sign-out, expiry, server stop, and app
quit revoke the appropriate terminals. Foreground processes receive hangup;
detached jobs may remain as they do after closing a local terminal window.
Terminals cannot currently be detached and reattached in another browser.
All authenticated operators share the same Mac-user scope and can end active
terminal sessions. There are no separate roles or per-user audit records.

Terminal output and access keys are not logged. Browser assets are bundled,
with no CDN or analytics. Terminal clipboard and clickable-link integrations are
disabled; terminal escape sequences cannot grant filesystem isolation. Browser
session cookies are never stored in localStorage.

## Provider and release scope

Inbound tunnels stay off until started and public sharing requires a native
confirmation. The app stops only processes it owns. Sharing another local web
service exposes that service's own authentication, not InfraProxy's key gate.
The browser server does not expose the outbound SOCKS proxy.

Tests cover actual loopback HTTP/WebSocket and PTY behavior plus provider
command construction. Real ngrok, Cloudflare, and tailnet reachability depends
on provider installation, account entitlements, network policy, and browser
TLS. Validate those routes in your environment before relying on remote access.

Source builds install pinned npm packages with lifecycle scripts disabled.
Release builds scan every Mach-O for arm64 and x86_64, sign nested executables,
notarize the app and DMG, and sign the Sparkle feed.
