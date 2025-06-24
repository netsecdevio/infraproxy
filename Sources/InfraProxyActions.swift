import Cocoa
import Foundation
import UserNotifications

// MARK: - InfraProxyManager Actions Extension
extension InfraProxyManager {
    
    // MARK: - Configuration Management
    func loadConfiguration() {
        let defaults = UserDefaults.standard
        
        if let proxy = defaults.string(forKey: "teleportProxy") {
            configuration.teleportProxy = proxy
        }
        if let host = defaults.string(forKey: "jumpboxHost") {
            configuration.jumpboxHost = host
        }
        if let port = defaults.string(forKey: "localPort") {
            configuration.localPort = port
        }
        if let path = defaults.string(forKey: "tshPath") {
            configuration.tshPath = path
        }
        if let httpPort = defaults.string(forKey: "httpProxyPort") {
            configuration.httpProxyPort = httpPort
        }
        if let httpPath = defaults.string(forKey: "httpProxyPath") {
            configuration.httpProxyPath = httpPath
        }
        
        configuration.killExistingProcesses = defaults.bool(forKey: "killExistingProcesses")
        configuration.httpProxyEnabled = defaults.bool(forKey: "httpProxyEnabled")
        self.log(.info, "Configuration loaded: \(configuration.teleportProxy), \(configuration.jumpboxHost), SOCKS port \(configuration.localPort), HTTP port \(configuration.httpProxyPort)")
    }
    
    private func saveConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(configuration.teleportProxy, forKey: "teleportProxy")
        defaults.set(configuration.jumpboxHost, forKey: "jumpboxHost")
        defaults.set(configuration.localPort, forKey: "localPort")
        defaults.set(configuration.tshPath, forKey: "tshPath")
        defaults.set(configuration.killExistingProcesses, forKey: "killExistingProcesses")
        defaults.set(configuration.httpProxyEnabled, forKey: "httpProxyEnabled")
        defaults.set(configuration.httpProxyPort, forKey: "httpProxyPort")
        defaults.set(configuration.httpProxyPath, forKey: "httpProxyPath")
        
        self.log(.info, "Configuration saved")
    }
    
    // MARK: - Port Management Helper
    private func checkPortContention(for port: String) -> [Int32] {
        let lsofProcess = Process()
        lsofProcess.launchPath = "/usr/sbin/lsof"
        lsofProcess.arguments = ["-ti", ":\(port)"]
        
        let pipe = Pipe()
        lsofProcess.standardOutput = pipe
        lsofProcess.standardError = Pipe()
        
        var pids: [Int32] = []
        
        do {
            try lsofProcess.run()
            lsofProcess.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                pids = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .compactMap { Int32($0) }
                    .filter { $0 > 0 }
            }
        } catch {
            // Silently handle errors for this helper method
        }
        
        return pids
    }
    
    // MARK: - Proxy Actions
    @objc func startProxy() {
        guard !isRunning else { return }
        
        if !isConfigurationValid() {
            showConfigurationError()
            return
        }
        
        if !handlePortContention() {
            self.log(.error, "Cannot start IA Proxy due to port contention")
            return
        }
        
        self.log(.info, "Starting IA Proxy...")
        
        checkTshStatusQuick { [weak self] isLoggedIn in
            if isLoggedIn {
                self?.startSocksProcess()
            } else {
                self?.startBackgroundLoginAndSocks()
            }
        }
    }
    
    @objc func stopProxy() {
        guard isRunning, let process = socksProcess else { return }
        
        self.log(.info, "Stopping IA Proxy process")
        process.terminate()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if process.isRunning {
                self?.log(.warning, "Process still running, sending interrupt signal")
                process.interrupt()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        self?.log(.warning, "Force terminating process")
                        process.terminate()
                    }
                }
            }
            self?.isRunning = false
            self?.updateMenuState()
            self?.showNotification(title: "IA Proxy Stopped", message: "InfraProxy has been stopped")
        }
    }
    
    @objc func restartProxy() {
        self.log(.info, "Restarting IA Proxy")
        stopProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startProxy()
        }
    }
    
    // MARK: - HTTP Proxy Actions
    @objc func startHttpProxy() {
        guard !isHttpProxyRunning else { return }
        
        if !configuration.httpProxyEnabled {
            let alert = NSAlert()
            alert.messageText = "HTTP Proxy Disabled"
            alert.informativeText = "HTTP Proxy is not enabled. Please enable it in Settings."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        
        // Check HTTP proxy port specifically
        let httpPids = checkPortContention(for: configuration.httpProxyPort)
        if !httpPids.isEmpty {
            if configuration.killExistingProcesses {
                self.log(.info, "Killing existing processes on HTTP port \(configuration.httpProxyPort)")
                killProcesses(httpPids)
            } else {
                let alert = NSAlert()
                alert.messageText = "HTTP Port Contention"
                alert.informativeText = "Port \(configuration.httpProxyPort) is in use by PIDs: \(httpPids.map(String.init).joined(separator: ", "))\n\nTerminate these processes?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Terminate & Continue")
                alert.addButton(withTitle: "Cancel")
                
                if alert.runModal() != .alertFirstButtonReturn {
                    return
                }
                killProcesses(httpPids)
            }
        }
        
        self.log(.info, "Starting HTTP Proxy...")
        
        httpProxyProcess = Process()
        httpProxyProcess?.launchPath = configuration.httpProxyPath
        httpProxyProcess?.arguments = ["-p", configuration.httpProxyPort]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        httpProxyProcess?.environment = environment
        
        let outputPipe = Pipe()
        httpProxyProcess?.standardOutput = outputPipe
        httpProxyProcess?.standardError = outputPipe
        
        httpProxyProcess?.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isHttpProxyRunning = false
                self?.updateMenuState()
                self?.log(.info, "HTTP Proxy terminated")
            }
        }
        
        do {
            try httpProxyProcess?.run()
            isHttpProxyRunning = true
            updateMenuState()
            self.log(.info, "HTTP Proxy started on port \(configuration.httpProxyPort)")
            showNotification(title: "HTTP Proxy Started", message: "Running on localhost:\(configuration.httpProxyPort)")
        } catch {
            self.log(.error, "Failed to start HTTP Proxy: \(error.localizedDescription)")
            showError(message: "Failed to start HTTP Proxy: \(error.localizedDescription)")
        }
    }

    @objc func stopHttpProxy() {
        guard isHttpProxyRunning, let process = httpProxyProcess else { return }
        
        self.log(.info, "Stopping HTTP Proxy")
        process.terminate()
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if process.isRunning {
                process.interrupt()
            }
            self?.isHttpProxyRunning = false
            self?.updateMenuState()
            self?.showNotification(title: "HTTP Proxy Stopped", message: "HTTP Proxy has been stopped")
        }
    }

    @objc func restartHttpProxy() {
        self.log(.info, "Restarting HTTP Proxy")
        stopHttpProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startHttpProxy()
        }
    }
    
    // MARK: - Settings Actions
    @objc func showSettings() {
        DispatchQueue.main.async { [weak self] in
            if self?.settingsWindow != nil {
                self?.settingsWindow?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            
            self?.createSettingsWindow()
            self?.settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    @objc func saveSettings() {
        if let proxyField = settingsFields.first(where: { $0.identifier?.rawValue == "proxyField" }) {
            configuration.teleportProxy = proxyField.stringValue
        }
        if let hostField = settingsFields.first(where: { $0.identifier?.rawValue == "hostField" }) {
            configuration.jumpboxHost = hostField.stringValue
        }
        if let portField = settingsFields.first(where: { $0.identifier?.rawValue == "portField" }) {
            configuration.localPort = portField.stringValue
        }
        if let pathField = settingsFields.first(where: { $0.identifier?.rawValue == "pathField" }) {
            configuration.tshPath = pathField.stringValue
        }
        
        // Save HTTP proxy settings
        if let httpEnabledCheckbox = settingsWindow?.contentView?.subviews.first(where: {
            ($0 as? NSButton)?.identifier?.rawValue == "httpEnabledCheckbox"
        }) as? NSButton {
            configuration.httpProxyEnabled = httpEnabledCheckbox.state == .on
        }

        if let httpPortField = settingsFields.first(where: { $0.identifier?.rawValue == "httpPortField" }) {
            configuration.httpProxyPort = httpPortField.stringValue
        }
        if let httpPathField = settingsFields.first(where: { $0.identifier?.rawValue == "httpPathField" }) {
            configuration.httpProxyPath = httpPathField.stringValue
        }
        
        configuration.killExistingProcesses = killProcessCheckbox?.state == .on
        
        saveConfiguration()
        updateMenuState()
        settingsWindow?.close()
        showNotification(title: "Settings Saved", message: "Configuration has been updated")
    }
    
    @objc func cancelSettings() {
        settingsWindow?.close()
    }
    
    @objc func browseTshPath() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = URL(fileURLWithPath: "/Applications")
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                if let pathField = settingsFields.first(where: { $0.identifier?.rawValue == "pathField" }) {
                    pathField.stringValue = url.path
                }
            }
        }
    }
    
    @objc func browseHttpPath() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false
        openPanel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        
        if openPanel.runModal() == .OK {
            if let url = openPanel.url {
                if let pathField = settingsFields.first(where: { $0.identifier?.rawValue == "httpPathField" }) {
                    pathField.stringValue = url.path
                }
            }
        }
    }
    
    @objc func checkPortUsage() {
        let socksPids = checkPortContention(for: configuration.localPort)
        var message = "SOCKS Port \(configuration.localPort): "
        message += socksPids.isEmpty ? "✅ Available" : "⚠️ In use by PIDs: \(socksPids.map(String.init).joined(separator: ", "))"
        
        if configuration.httpProxyEnabled {
            let httpPids = checkPortContention(for: configuration.httpProxyPort)
            message += "\n\nHTTP Port \(configuration.httpProxyPort): "
            message += httpPids.isEmpty ? "✅ Available" : "⚠️ In use by PIDs: \(httpPids.map(String.init).joined(separator: ", "))"
        }
        
        let alert = NSAlert()
        alert.messageText = "Port Status"
        alert.informativeText = message
        
        let allPortsAvailable = socksPids.isEmpty && (configuration.httpProxyEnabled ? checkPortContention(for: configuration.httpProxyPort).isEmpty : true)
        alert.alertStyle = allPortsAvailable ? .informational : .warning
        alert.runModal()
    }
    
    @objc func testConnection() {
        self.log(.info, "Testing connection with current settings")
        
        let testProcess = Process()
        testProcess.launchPath = "/bin/zsh"
        testProcess.arguments = ["-l", "-c", "\(configuration.tshPath) status"]
        
        let pipe = Pipe()
        testProcess.standardOutput = pipe
        testProcess.standardError = pipe
        
        testProcess.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            let exitCode = process.terminationStatus
            
            DispatchQueue.main.async {
                let message = exitCode == 0 ? "✅ Connected to Teleport" : "❌ Not connected to Teleport"
                self?.log(.info, "Connection test result: \(message)")
                self?.showNotification(title: "Connection Test", message: message)
                
                let alert = NSAlert()
                alert.messageText = "Connection Test Result"
                alert.informativeText = "\(message)\n\nOutput:\n\(output)"
                alert.alertStyle = exitCode == 0 ? .informational : .warning
                alert.runModal()
            }
        }
        
        do {
            try testProcess.run()
        } catch {
            self.log(.error, "Failed to test connection: \(error)")
            showError(message: "Failed to test connection: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Teleport Actions
    @objc func loginToTeleport() {
        // Check current login status first
        checkTshStatusQuick { [weak self] isLoggedIn in
            DispatchQueue.main.async {
                if isLoggedIn {
                    self?.performLogout()
                } else {
                    self?.performLogin()
                }
            }
        }
    }
    
    private func performLogin() {
        self.log(.info, "Starting Teleport login process")
        
        let loginProcess = Process()
        loginProcess.launchPath = "/bin/zsh"
        loginProcess.arguments = ["-l", "-c", "\(configuration.tshPath) login --proxy \(configuration.teleportProxy)"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        environment["PATH"] = "\(configuration.tshPath.replacingOccurrences(of: "/tsh", with: "")):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        loginProcess.environment = environment
        loginProcess.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let outputPipe = Pipe()
        loginProcess.standardOutput = outputPipe
        loginProcess.standardError = outputPipe
        
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            DispatchQueue.global(qos: .background).async {
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DispatchQueue.main.async {
                        self?.log(.info, "Login output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                    }
                }
            }
        }
        
        loginProcess.terminationHandler = { [weak self] process in
            outputHandle.readabilityHandler = nil
            
            DispatchQueue.main.async {
                let exitCode = process.terminationStatus
                self?.log(.info, "Login process exit code: \(exitCode)")
                
                if exitCode == 0 {
                    self?.showNotification(title: "Login Successful", message: "Successfully logged into Teleport")
                    self?.updateMenuState()
                } else {
                    self?.log(.error, "Login failed with exit code: \(exitCode)")
                    self?.showError(message: "Login failed with exit code \(exitCode)")
                }
            }
        }
        
        do {
            try loginProcess.run()
            showNotification(title: "Login Started", message: "Browser authentication required")
        } catch {
            self.log(.error, "Failed to start login process: \(error.localizedDescription)")
            showError(message: "Failed to start login process: \(error.localizedDescription)")
        }
    }
    
    private func performLogout() {
        self.log(.info, "Starting Teleport logout process")
        
        let logoutProcess = Process()
        logoutProcess.launchPath = "/bin/zsh"
        logoutProcess.arguments = ["-l", "-c", "\(configuration.tshPath) logout"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        logoutProcess.environment = environment
        logoutProcess.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let pipe = Pipe()
        logoutProcess.standardOutput = pipe
        logoutProcess.standardError = pipe
        
        logoutProcess.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                let exitCode = process.terminationStatus
                self?.log(.info, "Logout process exit code: \(exitCode)")
                
                if exitCode == 0 {
                    self?.showNotification(title: "Logout Successful", message: "Successfully logged out of Teleport")
                } else {
                    self?.log(.warning, "Logout completed with exit code: \(exitCode)")
                    self?.showNotification(title: "Logout Completed", message: "Teleport logout completed")
                }
                
                self?.updateMenuState()
            }
        }
        
        do {
            try logoutProcess.run()
            showNotification(title: "Logging Out", message: "Logging out of Teleport...")
        } catch {
            self.log(.error, "Failed to start logout process: \(error.localizedDescription)")
            showError(message: "Failed to start logout process: \(error.localizedDescription)")
        }
    }
    
    @objc func checkTeleportStatus() {
        self.log(.info, "Checking Teleport status")
        checkTshStatus { [weak self] isLoggedIn in
            let status = isLoggedIn ? "✅ Logged in" : "❌ Not logged in"
            self?.log(.info, "Teleport status: \(status)")
            self?.showNotification(title: "Teleport Status", message: status)
        }
    }
    
    @objc func listServers() {
        self.log(.info, "Listing available servers")
        
        let listProcess = Process()
        listProcess.launchPath = "/bin/zsh"
        listProcess.arguments = ["-l", "-c", "\(configuration.tshPath) ls"]
        
        let pipe = Pipe()
        listProcess.standardOutput = pipe
        listProcess.standardError = pipe
        
        listProcess.terminationHandler = { [weak self] process in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.log(.info, "Available servers:\n\(output)")
                    self?.showServerList(output)
                }
            }
        }
        
        do {
            try listProcess.run()
        } catch {
            self.log(.error, "Failed to list servers: \(error)")
            showError(message: "Failed to list servers: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Logs Actions
    @objc func showLogs() {
        if logsWindow == nil {
            createLogsWindow()
        }
        updateLogsWindow()
        logsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func clearLogs() {
        logEntries.removeAll()
        updateLogsWindow()
        self.log(.info, "Logs cleared")
    }
    
    @objc func exportLogs() {
        let savePanel = NSSavePanel()
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [.plainText]
        }
        savePanel.nameFieldStringValue = "infraproxy-logs-\(DateFormatter().string(from: Date())).txt"
        
        if savePanel.runModal() == .OK {
            if let url = savePanel.url {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                
                let logText = logEntries.map { entry in
                    "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
                }.joined(separator: "\n")
                
                do {
                    try logText.write(to: url, atomically: true, encoding: .utf8)
                    showNotification(title: "Logs Exported", message: "Logs saved to \(url.lastPathComponent)")
                } catch {
                    showError(message: "Failed to export logs: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - UI Helper Methods
    private func showServerList(_ serverList: String) {
        let alert = NSAlert()
        alert.messageText = "Available Teleport Servers"
        alert.informativeText = serverList.isEmpty ? "No servers found or not logged in." : serverList
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    private func createSettingsWindow() {
        if settingsWindow != nil {
            settingsWindow?.close()
            settingsWindow = nil
        }
        
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "InfraProxy Settings"
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
        
        settingsFields.removeAll()
        
        guard let contentView = settingsWindow?.contentView else { return }
        
        var yPosition: CGFloat = 540
        
        // Header
        let headerLabel = NSTextField(labelWithString: "Identity Aware (IA) Proxy Configuration")
        headerLabel.frame = NSRect(x: 20, y: yPosition, width: 480, height: 20)
        headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(headerLabel)
        
        yPosition -= 50
        
        // Teleport Proxy
        let proxyLabel = NSTextField(labelWithString: "Teleport Proxy:")
        proxyLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(proxyLabel)
        
        let proxyField = NSTextField()
        proxyField.frame = NSRect(x: 150, y: yPosition, width: 340, height: 22)
        proxyField.stringValue = configuration.teleportProxy
        proxyField.identifier = NSUserInterfaceItemIdentifier("proxyField")
        proxyField.isEditable = true
        proxyField.isSelectable = true
        proxyField.placeholderString = "teleport.example.com"
        contentView.addSubview(proxyField)
        settingsFields.append(proxyField)
        
        yPosition -= 35
        
        // Jumpbox Host
        let hostLabel = NSTextField(labelWithString: "Jumpbox Host:")
        hostLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(hostLabel)
        
        let hostField = NSTextField()
        hostField.frame = NSRect(x: 150, y: yPosition, width: 340, height: 22)
        hostField.stringValue = configuration.jumpboxHost
        hostField.identifier = NSUserInterfaceItemIdentifier("hostField")
        hostField.isEditable = true
        hostField.isSelectable = true
        hostField.placeholderString = "myjumpserver.example.com"
        contentView.addSubview(hostField)
        settingsFields.append(hostField)
        
        yPosition -= 35
        
        // SOCKS Port
        let portLabel = NSTextField(labelWithString: "SOCKS Port:")
        portLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(portLabel)
        
        let portField = NSTextField()
        portField.frame = NSRect(x: 150, y: yPosition, width: 100, height: 22)
        portField.stringValue = configuration.localPort
        portField.identifier = NSUserInterfaceItemIdentifier("portField")
        portField.isEditable = true
        portField.isSelectable = true
        portField.placeholderString = "2222"
        contentView.addSubview(portField)
        settingsFields.append(portField)
        
        yPosition -= 35
        
        // TSH Path
        let pathLabel = NSTextField(labelWithString: "TSH Path:")
        pathLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(pathLabel)
        
        let pathField = NSTextField()
        pathField.frame = NSRect(x: 150, y: yPosition, width: 270, height: 22)
        pathField.stringValue = configuration.tshPath
        pathField.identifier = NSUserInterfaceItemIdentifier("pathField")
        pathField.isEditable = true
        pathField.isSelectable = true
        contentView.addSubview(pathField)
        settingsFields.append(pathField)
        
        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseTshPath))
        browseButton.frame = NSRect(x: 430, y: yPosition, width: 70, height: 22)
        contentView.addSubview(browseButton)
        
        yPosition -= 50
        
        // HTTP Proxy section separator
        let separatorLine = NSBox()
        separatorLine.frame = NSRect(x: 20, y: yPosition, width: 480, height: 1)
        separatorLine.boxType = .separator
        contentView.addSubview(separatorLine)
        
        yPosition -= 30
        
        // HTTP Proxy section header
        let httpProxyLabel = NSTextField(labelWithString: "HTTP Proxy Configuration")
        httpProxyLabel.frame = NSRect(x: 20, y: yPosition, width: 480, height: 20)
        httpProxyLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(httpProxyLabel)
        
        yPosition -= 40
        
        // Enable HTTP Proxy checkbox
        let httpEnabledCheckbox = NSButton(checkboxWithTitle: "Enable HTTP Proxy", target: nil, action: nil)
        httpEnabledCheckbox.frame = NSRect(x: 20, y: yPosition, width: 200, height: 20)
        httpEnabledCheckbox.state = configuration.httpProxyEnabled ? .on : .off
        httpEnabledCheckbox.identifier = NSUserInterfaceItemIdentifier("httpEnabledCheckbox")
        contentView.addSubview(httpEnabledCheckbox)
        
        yPosition -= 35
        
        // HTTP Proxy Port
        let httpPortLabel = NSTextField(labelWithString: "HTTP Port:")
        httpPortLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(httpPortLabel)
        
        let httpPortField = NSTextField()
        httpPortField.frame = NSRect(x: 150, y: yPosition, width: 100, height: 22)
        httpPortField.stringValue = configuration.httpProxyPort
        httpPortField.identifier = NSUserInterfaceItemIdentifier("httpPortField")
        httpPortField.isEditable = true
        httpPortField.isSelectable = true
        httpPortField.placeholderString = "8080"
        contentView.addSubview(httpPortField)
        settingsFields.append(httpPortField)
        
        yPosition -= 35
        
        // HTTP Proxy Path
        let httpPathLabel = NSTextField(labelWithString: "HPTS Path:")
        httpPathLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(httpPathLabel)
        
        let httpPathField = NSTextField()
        httpPathField.frame = NSRect(x: 150, y: yPosition, width: 270, height: 22)
        httpPathField.stringValue = configuration.httpProxyPath
        httpPathField.identifier = NSUserInterfaceItemIdentifier("httpPathField")
        httpPathField.isEditable = true
        httpPathField.isSelectable = true
        httpPathField.placeholderString = "/usr/local/bin/hpts"
        contentView.addSubview(httpPathField)
        settingsFields.append(httpPathField)
        
        let browseHttpButton = NSButton(title: "Browse...", target: self, action: #selector(browseHttpPath))
        browseHttpButton.frame = NSRect(x: 430, y: yPosition, width: 70, height: 22)
        contentView.addSubview(browseHttpButton)
        
        yPosition -= 50
        
        // Port Management section separator
        let separatorLine2 = NSBox()
        separatorLine2.frame = NSRect(x: 20, y: yPosition, width: 480, height: 1)
        separatorLine2.boxType = .separator
        contentView.addSubview(separatorLine2)
        
        yPosition -= 30
        
        // Port Management section
        let portManagementLabel = NSTextField(labelWithString: "Port Management")
        portManagementLabel.frame = NSRect(x: 20, y: yPosition, width: 480, height: 20)
        portManagementLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(portManagementLabel)
        
        yPosition -= 35
        
        // Kill existing processes checkbox
        killProcessCheckbox = NSButton(checkboxWithTitle: "Automatically terminate processes using the same port", target: nil, action: nil)
        killProcessCheckbox?.frame = NSRect(x: 20, y: yPosition, width: 450, height: 20)
        killProcessCheckbox?.state = configuration.killExistingProcesses ? .on : .off
        contentView.addSubview(killProcessCheckbox!)
        
        yPosition -= 25
        
        let warningLabel = NSTextField(labelWithString: "⚠️ Warning: This will forcefully terminate other processes using configured ports")
        warningLabel.frame = NSRect(x: 20, y: yPosition, width: 480, height: 20)
        warningLabel.font = NSFont.systemFont(ofSize: 10)
        warningLabel.textColor = .systemOrange
        contentView.addSubview(warningLabel)
        
        // Buttons at bottom
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 420, y: 20, width: 80, height: 30)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancelButton.frame = NSRect(x: 330, y: 20, width: 80, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)
        
        // Test connection button
        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 20, y: 20, width: 120, height: 30)
        contentView.addSubview(testButton)
        
        // Check ports button
        let checkPortButton = NSButton(title: "Check Ports", target: self, action: #selector(checkPortUsage))
        checkPortButton.frame = NSRect(x: 150, y: 20, width: 100, height: 30)
        contentView.addSubview(checkPortButton)
    }
    
    private func createLogsWindow() {
        logsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        logsWindow?.title = "InfraProxy Logs"
        logsWindow?.center()
        
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 0, y: 40, width: 800, height: 560)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        
        let textView = NSTextView()
        textView.isEditable = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.identifier = NSUserInterfaceItemIdentifier("logTextView")
        
        scrollView.documentView = textView
        logsWindow?.contentView?.addSubview(scrollView)
        
        // Clear button
        let clearButton = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogs))
        clearButton.frame = NSRect(x: 20, y: 10, width: 100, height: 25)
        logsWindow?.contentView?.addSubview(clearButton)
        
        // Export button
        let exportButton = NSButton(title: "Export Logs", target: self, action: #selector(exportLogs))
        exportButton.frame = NSRect(x: 130, y: 10, width: 100, height: 25)
        logsWindow?.contentView?.addSubview(exportButton)
    }
    
    private func updateLogsWindow() {
        guard let scrollView = logsWindow?.contentView?.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        
        let logText = logEntries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
        
        textView.string = logText
        textView.scrollToEndOfDocument(nil)
    }
}

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    var infraProxyManager: InfraProxyManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        if #available(macOS 10.14, *) {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    print("Notification permission error: \(error)")
                }
            }
        }
        
        infraProxyManager = InfraProxyManager()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        infraProxyManager = nil
    }
}
