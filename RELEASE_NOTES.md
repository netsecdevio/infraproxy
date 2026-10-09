# InfraProxy 2.7.0

- Adds an authenticated browser dashboard with live Teleport expiry, local connection statistics, inbound URLs, and interactive terminal sessions on this Mac.
- Adds inbound ngrok HTTPS access alongside Tailscale Serve/Funnel and Cloudflare Quick Tunnels. Choose the InfraProxy dashboard or an existing local web service.
- Redesigns Inbound settings with authentication, destination, provider status, private/public Tailscale controls, and discovered tailnet devices.
- Adds About and Advanced tabs with version and project links, open-source credits, preferred Terminal/iTerm2, update controls, and debug logging.
- Browser access requires a rotating key, uses eight-hour sessions and single-use terminal tickets, and binds only to localhost. Restart or rotate the key to revoke access. Inbound sharing remains off until explicitly started.
- Defaults to port 4021 so InfraProxy can coexist with VibeTunnel on port 4020.
- Ships Universal 2 binaries, including the new native PTY helper, for Apple Silicon and Intel. Signed and notarized for macOS 15.5 and later.

Use **Check for Updates…** to install and relaunch. Stop active browser terminals before updating; their shells end when the app quits. Detached jobs may continue.

Validation covers native UI, real browser login and terminal I/O, PTY resizing and interrupts, authentication/origin checks, key revocation, bounded request parsing, and Universal 2 packaging. Public-provider routing requires your provider account and policy; no public tunnel is enabled by this update.
