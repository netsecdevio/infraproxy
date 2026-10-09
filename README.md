# infravibe

Formerly InfraProxy. Published releases still use the `InfraProxy.app` bundle  while the rebrand is in development. Existing bundle identifiers and settings paths are retained for upgrade compatibility.

## Contributing

Start with [CONTRIBUTING.md](CONTRIBUTING.md) for setup, tests, and pull requests. See our [Code of Conduct](CODE_OF_CONDUCT.md) and [security policy](SECURITY.md). Report reproducible bugs or propose features through [GitHub Issues](https://github.com/netsecdevio/infravibe/issues).

A macOS menu bar application for managing Identity Aware (IA) Proxy connections through Teleport. Provides secure access to internal resources via SOCKS proxy tunneling.

![macOS](https://img.shields.io/badge/macOS-15.5%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Menu panel and remote access

Click the menu bar icon for the compact status panel: Teleport expiry, local
listeners and TCP sessions, Tailscale connectivity, and cloud shortcuts. The
**Appearance** control supports System, Light, and Dark themes. Right-click the
icon for the existing advanced proxy and launch-service controls.

Open **Tailscale** in the panel, or **Operations → Inbound**, to discover your
Mac and tailnet devices from the installed Tailscale client. Use **Open Tailscale**
for provider sign-in and connection management.

To share a local web application, enter its listening port and choose:

- **Tailscale Serve**: private HTTPS within your tailnet, subject to tailnet policy.
- **Tailscale Funnel**: public HTTPS, requiring Funnel permission in Tailscale.
- **ngrok**: public HTTPS using your installed, authenticated ngrok agent.
- **Cloudflare**: a temporary public Quick Tunnel using installed `cloudflared`.

Sharing requires an explicit confirmation. InfraProxy owns only the foreground
tunnels it starts; stopping one preserves other tunnels. Tailscale sharing uses
HTTPS port 8443 and refuses an occupied port. Existing Cloudflare configuration
files are preserved; use the Cloudflare console to manage named tunnels.
Configured infrastructure proxy ports cannot be shared.

### Browser dashboard and terminals (2.7.0+)

Open **Dashboard**, start the browser server, then choose **Open Browser**. The
server binds only to `127.0.0.1` (default port 4021). Its browser dashboard shows
Teleport expiry, local listeners, TCP sessions, inbound URLs, and interactive
terminals running as your Mac user. Both local and remote browsers authenticate.

In **Inbound**, choose the InfraProxy dashboard or another local web service,
then select a provider. Copy the access key from the Authentication section to
sign in remotely. Tailscale's private tailnet mode is the default; public Funnel,
ngrok, and Cloudflare sharing require an explicit confirmation. Provider account
setup stays with the installed provider tools; InfraProxy never asks you to paste
provider credentials into its settings.

Browser sessions last eight hours. Restarting the server changes its key;
**Rotate key** revokes browser sessions immediately. A disconnected terminal ends
its shell; detached jobs may continue. Sharing and the browser server are off on
launch. See [browser access security and limitations](BROWSER_ACCESS.md).

**Advanced** contains terminal preferences, update checks, and debug logging.
**About** shows the installed version, project links, and open-source credits.

The menu design and sharing workflow draw inspiration from
[VibeTunnel](https://github.com/amantus-ai/vibetunnel); see [notices](THIRD_PARTY_NOTICES.md).

## Architecture

Release 2.6.1 and later are Universal 2: one app runs natively on both Apple Silicon
(`arm64`) and Intel (`x86_64`) Macs running macOS 15.5 or later. The build compiles
both architectures and verifies every bundled executable, including Sparkle helpers.

## In-app updates (2.6.0+)

Use **Check for Updates…** in the menu bar or **Operations → Advanced**. InfraProxy checks daily and offers signed updates for installation and relaunch. Automatic checks can be disabled in the Advanced tab. Install v2.6.0 once to enable this on older installations.

Release maintainers: see [UPDATING.md](UPDATING.md) for the signed-feed publishing workflow.

## Google Cloud integration

Open **Google Cloud** in the menu panel. InfraProxy discovers installed gcloud accounts and accessible projects automatically. Use **Sign in / Add account** or **Reauthenticate** to authenticate in your browser with the methods offered by Google or your organization, including supported passkeys and hardware security keys.

Choose a populated project and browse VMs, Storage, Cloud SQL, Kubernetes, Cloud Run, or VPC networks. VM start/stop and IAP SSH are available in the app; Cloud Console links open further project management, logs, IAM, and APIs. A Google Cloud CLI installation is required and detected automatically, with an install link and file picker when necessary.

The dashboard also shows the Teleport credential-expiry countdown and per-port TCP sessions. See [release notes](RELEASE_NOTES.md) for setup and validation scope.

## Features

- **Menu Bar Integration**: Lightweight system tray application
- **Port Management**: Automatic detection and resolution of port conflicts
- **Teleport Authentication**: Seamless integration with `tsh` client
- **SOCKS Proxy**: Secure tunneling to internal resources
- **Configuration UI**: Easy setup through settings panel
- **Logging System**: Comprehensive logging with export capabilities
- **Process Management**: Smart handling of existing proxy processes

## Prerequisites

- macOS 15.5 (Sequoia) or later
- Xcode command-line tools and Node.js/npm for source builds
- Provider CLIs and accounts for the integrations you use (Teleport, Google Cloud, Tailscale, ngrok, or Cloudflare)

## Installation

### Homebrew

```bash
brew tap netsecdevio/infravibe https://github.com/netsecdevio/infravibe
brew trust --cask netsecdevio/infravibe/infravibe
brew install --cask netsecdevio/infravibe/infravibe
```

The cask downloads the same signed, notarized Universal 2 release and verifies
its SHA-256 checksum. macOS 15.5 or later is required. Optional provider tools
are installed separately. Use the in-app updater, or:

```bash
brew update
brew upgrade --cask --greedy infravibe
```

An existing manually installed copy should be updated in-app; Homebrew will not
overwrite it without an explicit migration. Uninstalling the cask preserves
configuration and session history.

### Option 1: Download Release
1. Download `InfraProxy.app` from [Releases](../../releases)
2. Move to `/Applications` folder
3. Open the signed, notarized app.

### Option 2: Build from Source
```bash
git clone https://github.com/netsecdevio/infravibe.git
cd infravibe
chmod +x build.sh
./build.sh
```

## Configuration

On first launch, configure the following in Settings:

| Setting | Description | Example |
|---------|-------------|---------|
| **Teleport Proxy** | Your Teleport cluster URL | `teleport.company.com` |
| **Jumpbox Host** | Target server for tunneling | `jumpserver.internal.com` |
| **Local Port** | SOCKS proxy port (1024-65535) | `2222` |
| **TSH Path** | Path to Teleport client | `/usr/local/bin/tsh` |

### Port Management
- **Auto-terminate**: Automatically kill processes using the same port
- **Manual prompt**: Ask before terminating conflicting processes

## Usage

### Starting the Proxy
1. Click **Start IA Proxy** from menu
2. Authenticate via browser if needed
3. Use `localhost:[port]` as SOCKS proxy in applications

### Menu Options
- **Start/Stop/Restart IA Proxy**: Control proxy state
- **Login to Teleport**: Manual authentication
- **Check Status**: Verify Teleport connection
- **Settings**: Configure proxy parameters
- **Show Logs**: View detailed operation logs
- **List Available Servers**: Browse accessible hosts

### Using the Proxy
Configure applications to use SOCKS proxy:
```
Host: localhost
Port: [configured port, default 2222]
Type: SOCKS5
```

## Browser Configuration

### Chrome/Chromium
```bash
google-chrome --proxy-server="socks5://localhost:2222"
```

### Firefox
1. Settings → Network Settings → Manual proxy configuration
2. SOCKS Host: `localhost`, Port: `2222`
3. Select "SOCKS v5"

### macOS System-wide
```bash
# Set proxy
networksetup -setsocksfirewallproxy "Wi-Fi" localhost 2222

# Remove proxy
networksetup -setsocksfirewallproxystate "Wi-Fi" off
```

## Troubleshooting

### Common Issues

**App won't start**
- Ensure macOS 15.5+
- Check that `tsh` is installed and accessible
- Review system logs: `Console.app → Log Reports`

**Authentication failures**
- Verify Teleport proxy URL
- Check network connectivity
- Try manual login: `tsh login --proxy your-proxy.com`

**Port conflicts**
- Enable auto-terminate in settings, or
- Check port usage: `lsof -i :2222`
- Choose different port in settings

**Connection timeouts**
- Verify jumpbox hostname
- Check Teleport permissions for target server
- Review logs for detailed error messages

### Debug Mode
Enable detailed logging:
1. Enable **Advanced → Debug mode**
2. Open **Show Logs**
3. Check operational diagnostics; terminal content and browser access keys are not recorded.

## Security Considerations

- Proxy traffic is encrypted via SSH tunnel
- No credentials stored locally (handled by `tsh`)
- Menu bar app runs with user privileges only
- Port binding limited to localhost interface

## Development

### Building
```bash
# Direct compilation
./build.sh

# Targeted regression checks
bash Tests/run.sh

# Using build script
./build.sh
```

### Architecture
- `ProxyModels.swift`: Data structures and configuration
- `InfraProxyManager.swift`: Core proxy management and menu bar
- `InfraProxyActions.swift`: UI actions and Teleport integration
- `main.swift`: Application entry point

### Contributing
1. Fork the repository
2. Create feature branch
3. Test on multiple macOS versions
4. Submit pull request

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- **Issues**: [GitHub Issues](../../issues)
- **Documentation**: [Wiki](../../wiki)
- **Security**: Report via email (not public issues)

## Changelog

### v1.0.0
- Initial release
- Menu bar integration
- Port conflict management
- Teleport authentication
- SOCKS proxy tunneling
- Configuration UI
- Logging system

---

**Note**: This application requires appropriate network access and Teleport cluster permissions. Contact your system administrator for access credentials.

### Homebrew tap trust and older installations

Homebrew requires explicit trust for third-party package definitions. The command above trusts only the infravibe cask, not every current or future item in the tap. See [Homebrew Tap Trust](https://docs.brew.sh/Tap-Trust).

If you previously added `netsecdevio/infraproxy`, add the new tap using the commands above. Only remove the old tap with `brew untap netsecdevio/infraproxy` after migrating any installed casks; do not force-remove a tap with installed packages.

The cask is named `infravibe`. The current stable 2.7.0 artifact still contains `InfraProxy.app` and its original interface; the full application rebrand is not yet released. The signed bundle is intentionally not rewritten by Homebrew.
