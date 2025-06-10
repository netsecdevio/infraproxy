# InfraProxy

A macOS menu bar application for managing Identity Aware (IA) Proxy connections through Teleport. Provides secure access to internal resources via SOCKS proxy tunneling.

![macOS](https://img.shields.io/badge/macOS-15.5%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.7%2B-orange)
![License](https://img.shields.io/badge/License-MIT-green)

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
- [Teleport](https://goteleport.com/) SSH client (`tsh`) installed
- Valid Teleport cluster access credentials

## Installation

### Option 1: Download Release
1. Download `InfraProxy.app` from [Releases](../../releases)
2. Move to `/Applications` folder
3. Right-click → Open → Open (to bypass Gatekeeper on first launch)

### Option 2: Build from Source
```bash
git clone https://github.com/netsecdevio/infraproxy.git
cd infraproxy
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
1. Open **Show Logs**
2. Check for ERROR/WARN messages
3. Export logs for troubleshooting

## Security Considerations

- Proxy traffic is encrypted via SSH tunnel
- No credentials stored locally (handled by `tsh`)
- Menu bar app runs with user privileges only
- Port binding limited to localhost interface

## Development

### Building
```bash
# Direct compilation
swiftc -o InfraProxy Sources/*.swift -framework Cocoa -framework UserNotifications

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
