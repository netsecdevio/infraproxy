import Cocoa
import Foundation
import UserNotifications

// MARK: - InfraProxyManager Actions Extension
extension InfraProxyManager {

    // MARK: - Configuration Management

    func loadConfiguration() {
        let defaults = UserDefaults.standard

        // Load Teleport settings
        if let proxy = defaults.string(forKey: ConfigKeys.teleportProxy) {
            configuration.teleport.teleportProxy = proxy
        }
        if let host = defaults.string(forKey: ConfigKeys.jumpboxHost) {
            configuration.teleport.jumpboxHost = host
        }
        if let port = defaults.string(forKey: ConfigKeys.localPort) {
            configuration.teleport.localPort = port
        }
        if let path = defaults.string(forKey: ConfigKeys.tshPath) {
            configuration.teleport.tshPath = path
        }

        // Load HTTP proxy settings
        if let httpPort = defaults.string(forKey: ConfigKeys.httpProxyPort) {
            configuration.httpProxy.port = httpPort
        }
        if let httpPath = defaults.string(forKey: ConfigKeys.httpProxyPath) {
            configuration.httpProxy.path = httpPath
        }
        configuration.httpProxy.enabled = defaults.bool(forKey: ConfigKeys.httpProxyEnabled)

        // Load general settings
        configuration.killExistingProcesses = defaults.bool(forKey: ConfigKeys.killExistingProcesses)

        if defaults.object(forKey: ConfigKeys.showNotifications) != nil {
            configuration.showNotifications = defaults.bool(forKey: ConfigKeys.showNotifications)
        } else {
            configuration.showNotifications = true
        }

        // Load launchctl services from JSON
        if let data = defaults.data(forKey: ConfigKeys.launchctlServices) {
            do {
                let services = try JSONDecoder().decode([LaunchctlService].self, from: data)
                configuration.services = services
                log(.info, "Loaded \(services.count) launchctl services")
            } catch {
                log(.error, "Failed to decode services: \(error.localizedDescription)")
                configuration.services = []
            }
        }

        log(.info, "Configuration loaded")
    }

    internal func saveConfiguration() {
        let defaults = UserDefaults.standard

        // Save Teleport settings
        defaults.set(configuration.teleport.teleportProxy, forKey: ConfigKeys.teleportProxy)
        defaults.set(configuration.teleport.jumpboxHost, forKey: ConfigKeys.jumpboxHost)
        defaults.set(configuration.teleport.localPort, forKey: ConfigKeys.localPort)
        defaults.set(configuration.teleport.tshPath, forKey: ConfigKeys.tshPath)

        // Save HTTP proxy settings
        defaults.set(configuration.httpProxy.enabled, forKey: ConfigKeys.httpProxyEnabled)
        defaults.set(configuration.httpProxy.port, forKey: ConfigKeys.httpProxyPort)
        defaults.set(configuration.httpProxy.path, forKey: ConfigKeys.httpProxyPath)

        // Save general settings
        defaults.set(configuration.killExistingProcesses, forKey: ConfigKeys.killExistingProcesses)
        defaults.set(configuration.showNotifications, forKey: ConfigKeys.showNotifications)

        // Save launchctl services as JSON
        do {
            let data = try JSONEncoder().encode(configuration.services)
            defaults.set(data, forKey: ConfigKeys.launchctlServices)
        } catch {
            log(.error, "Failed to encode services: \(error.localizedDescription)")
        }

        log(.info, "Configuration saved")
    }

    // MARK: - Teleport Proxy Actions

    @objc func startProxy() {
        guard !isRunning else { return }

        if !isConfigurationValid() {
            showConfigurationError()
            return
        }

        // Check SOCKS port contention
        let socksPids = checkPortContentionForPort(configuration.teleport.localPort)
        if !socksPids.isEmpty {
            if configuration.killExistingProcesses {
                log(.info, "Killing existing processes on SOCKS port")
                killProcesses(socksPids)
            } else if !showPortContentionDialog(pids: socksPids) {
                return
            }
        }

        log(.info, "Starting IA Proxy...")

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

        log(.info, "Stopping IA Proxy process")
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
            self?.rebuildMenu()
            self?.showNotification(title: "IA Proxy Stopped", message: "InfraProxy has been stopped")
        }
    }

    @objc func restartProxy() {
        log(.info, "Restarting IA Proxy")
        stopProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.startProxy()
        }
    }

    // MARK: - HTTP Proxy Actions

    @objc func startHttpProxy() {
        guard !isHttpProxyRunning else { return }

        if !configuration.httpProxy.enabled {
            let alert = NSAlert()
            alert.messageText = "HTTP Proxy Disabled"
            alert.informativeText = "HTTP Proxy is not enabled. Please enable it in Settings."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Check HTTP proxy port
        let httpPids = checkPortContentionForPort(configuration.httpProxy.port)
        if !httpPids.isEmpty {
            if configuration.killExistingProcesses {
                log(.info, "Killing existing processes on HTTP port \(configuration.httpProxy.port)")
                killProcesses(httpPids)
            } else {
                let alert = NSAlert()
                alert.messageText = "HTTP Port Contention"
                alert.informativeText = "Port \(configuration.httpProxy.port) is in use by PIDs: \(httpPids.map(String.init).joined(separator: ", "))\n\nTerminate these processes?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Terminate & Continue")
                alert.addButton(withTitle: "Cancel")

                if alert.runModal() != .alertFirstButtonReturn {
                    return
                }
                killProcesses(httpPids)
            }
        }

        log(.info, "Starting HTTP Proxy...")

        httpProxyProcess = Process()
        httpProxyProcess?.launchPath = configuration.httpProxy.path
        httpProxyProcess?.arguments = ["-p", configuration.httpProxy.port]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        httpProxyProcess?.environment = environment

        let outputPipe = Pipe()
        httpProxyProcess?.standardOutput = outputPipe
        httpProxyProcess?.standardError = outputPipe

        httpProxyProcess?.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.isHttpProxyRunning = false
                self?.rebuildMenu()
                self?.log(.info, "HTTP Proxy terminated")
            }
        }

        do {
            try httpProxyProcess?.run()
            isHttpProxyRunning = true
            rebuildMenu()
            log(.info, "HTTP Proxy started on port \(configuration.httpProxy.port)")
            showNotification(title: "HTTP Proxy Started", message: "Running on localhost:\(configuration.httpProxy.port)")
        } catch {
            log(.error, "Failed to start HTTP Proxy: \(error.localizedDescription)")
            showError(message: "Failed to start HTTP Proxy: \(error.localizedDescription)")
        }
    }

    @objc func stopHttpProxy() {
        guard isHttpProxyRunning, let process = httpProxyProcess else { return }

        log(.info, "Stopping HTTP Proxy")
        process.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            if process.isRunning {
                process.interrupt()
            }
            self?.isHttpProxyRunning = false
            self?.rebuildMenu()
            self?.showNotification(title: "HTTP Proxy Stopped", message: "HTTP Proxy has been stopped")
        }
    }

    @objc func restartHttpProxy() {
        log(.info, "Restarting HTTP Proxy")
        stopHttpProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.startHttpProxy()
        }
    }

    // MARK: - Teleport Login Actions

    @objc func loginToTeleport() {
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
        log(.info, "Starting Teleport login process")

        let loginProcess = Process()
        loginProcess.launchPath = "/bin/zsh"
        loginProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) login --proxy \(configuration.teleport.teleportProxy)"]

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        environment["PATH"] = "\(configuration.teleport.tshPath.replacingOccurrences(of: "/tsh", with: "")):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
                    self?.rebuildMenu()
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
            log(.error, "Failed to start login process: \(error.localizedDescription)")
            showError(message: "Failed to start login process: \(error.localizedDescription)")
        }
    }

    private func performLogout() {
        log(.info, "Starting Teleport logout process")

        let logoutProcess = Process()
        logoutProcess.launchPath = "/bin/zsh"
        logoutProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) logout"]

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

                self?.rebuildMenu()
            }
        }

        do {
            try logoutProcess.run()
            showNotification(title: "Logging Out", message: "Logging out of Teleport...")
        } catch {
            log(.error, "Failed to start logout process: \(error.localizedDescription)")
            showError(message: "Failed to start logout process: \(error.localizedDescription)")
        }
    }

    @objc func checkTeleportStatus() {
        log(.info, "Checking Teleport status")
        checkTshStatus { [weak self] isLoggedIn in
            let status = isLoggedIn ? "✅ Logged in" : "❌ Not logged in"
            self?.log(.info, "Teleport status: \(status)")
            self?.showNotification(title: "Teleport Status", message: status)
        }
    }

    @objc func listServers() {
        log(.info, "Listing available servers")

        let listProcess = Process()
        listProcess.launchPath = "/bin/zsh"
        listProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) ls"]

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
            log(.error, "Failed to list servers: \(error)")
            showError(message: "Failed to list servers: \(error.localizedDescription)")
        }
    }

    private func showServerList(_ serverList: String) {
        let alert = NSAlert()
        alert.messageText = "Available Teleport Servers"
        alert.informativeText = serverList.isEmpty ? "No servers found or not logged in." : serverList
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Port Check Action

    @objc func checkPortUsage() {
        var message = ""

        // Check SOCKS port
        let socksPids = checkPortContentionForPort(configuration.teleport.localPort)
        message += "SOCKS Port \(configuration.teleport.localPort): "
        message += socksPids.isEmpty ? "✅ Available" : "⚠️ In use by PIDs: \(socksPids.map(String.init).joined(separator: ", "))"

        // Check HTTP port
        if configuration.httpProxy.enabled {
            let httpPids = checkPortContentionForPort(configuration.httpProxy.port)
            message += "\n\nHTTP Port \(configuration.httpProxy.port): "
            message += httpPids.isEmpty ? "✅ Available" : "⚠️ In use by PIDs: \(httpPids.map(String.init).joined(separator: ", "))"
        }

        let alert = NSAlert()
        alert.messageText = "Port Status"
        alert.informativeText = message
        alert.alertStyle = socksPids.isEmpty ? .informational : .warning
        alert.runModal()
    }

    // MARK: - Settings Window

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

    private func createSettingsWindow() {
        if settingsWindow != nil {
            settingsWindow?.close()
            settingsWindow = nil
        }

        // Copy services for editing
        editingServices = configuration.services
        settingsFields.removeAll()

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "InfraProxy Settings"
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false

        guard let contentView = settingsWindow?.contentView else { return }

        var yPosition: CGFloat = 660

        // === TELEPORT SECTION ===
        let teleportHeader = NSTextField(labelWithString: "Teleport Configuration")
        teleportHeader.frame = NSRect(x: 20, y: yPosition, width: 520, height: 20)
        teleportHeader.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(teleportHeader)

        yPosition -= 35

        // Teleport Proxy
        let proxyLabel = NSTextField(labelWithString: "Teleport Proxy:")
        proxyLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(proxyLabel)

        let proxyField = NSTextField()
        proxyField.frame = NSRect(x: 150, y: yPosition, width: 380, height: 22)
        proxyField.stringValue = configuration.teleport.teleportProxy
        proxyField.identifier = NSUserInterfaceItemIdentifier("proxyField")
        proxyField.placeholderString = "teleport.example.com"
        contentView.addSubview(proxyField)
        settingsFields.append(proxyField)

        yPosition -= 30

        // Jumpbox Host
        let hostLabel = NSTextField(labelWithString: "Jumpbox Host:")
        hostLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(hostLabel)

        let hostField = NSTextField()
        hostField.frame = NSRect(x: 150, y: yPosition, width: 380, height: 22)
        hostField.stringValue = configuration.teleport.jumpboxHost
        hostField.identifier = NSUserInterfaceItemIdentifier("hostField")
        hostField.placeholderString = "jumpbox.example.com"
        contentView.addSubview(hostField)
        settingsFields.append(hostField)

        yPosition -= 30

        // SOCKS Port
        let portLabel = NSTextField(labelWithString: "SOCKS Port:")
        portLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(portLabel)

        let portField = NSTextField()
        portField.frame = NSRect(x: 150, y: yPosition, width: 80, height: 22)
        portField.stringValue = configuration.teleport.localPort
        portField.identifier = NSUserInterfaceItemIdentifier("portField")
        portField.placeholderString = "2222"
        contentView.addSubview(portField)
        settingsFields.append(portField)

        yPosition -= 30

        // TSH Path
        let pathLabel = NSTextField(labelWithString: "TSH Path:")
        pathLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(pathLabel)

        let pathField = NSTextField()
        pathField.frame = NSRect(x: 150, y: yPosition, width: 310, height: 22)
        pathField.stringValue = configuration.teleport.tshPath
        pathField.identifier = NSUserInterfaceItemIdentifier("pathField")
        contentView.addSubview(pathField)
        settingsFields.append(pathField)

        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseTshPath))
        browseButton.frame = NSRect(x: 470, y: yPosition, width: 70, height: 22)
        contentView.addSubview(browseButton)

        yPosition -= 40

        // === HTTP PROXY SECTION ===
        let separatorLine1 = NSBox()
        separatorLine1.frame = NSRect(x: 20, y: yPosition, width: 520, height: 1)
        separatorLine1.boxType = .separator
        contentView.addSubview(separatorLine1)

        yPosition -= 25

        let httpHeader = NSTextField(labelWithString: "HTTP Proxy Configuration")
        httpHeader.frame = NSRect(x: 20, y: yPosition, width: 520, height: 20)
        httpHeader.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(httpHeader)

        yPosition -= 30

        let httpEnabledCheckbox = NSButton(checkboxWithTitle: "Enable HTTP Proxy (HPTS)", target: nil, action: nil)
        httpEnabledCheckbox.frame = NSRect(x: 20, y: yPosition, width: 250, height: 20)
        httpEnabledCheckbox.state = configuration.httpProxy.enabled ? .on : .off
        httpEnabledCheckbox.identifier = NSUserInterfaceItemIdentifier("httpEnabledCheckbox")
        contentView.addSubview(httpEnabledCheckbox)

        yPosition -= 30

        let httpPortLabel = NSTextField(labelWithString: "HTTP Port:")
        httpPortLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(httpPortLabel)

        let httpPortField = NSTextField()
        httpPortField.frame = NSRect(x: 150, y: yPosition, width: 80, height: 22)
        httpPortField.stringValue = configuration.httpProxy.port
        httpPortField.identifier = NSUserInterfaceItemIdentifier("httpPortField")
        httpPortField.placeholderString = "8080"
        contentView.addSubview(httpPortField)
        settingsFields.append(httpPortField)

        yPosition -= 30

        let httpPathLabel = NSTextField(labelWithString: "HPTS Path:")
        httpPathLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(httpPathLabel)

        let httpPathField = NSTextField()
        httpPathField.frame = NSRect(x: 150, y: yPosition, width: 310, height: 22)
        httpPathField.stringValue = configuration.httpProxy.path
        httpPathField.identifier = NSUserInterfaceItemIdentifier("httpPathField")
        contentView.addSubview(httpPathField)
        settingsFields.append(httpPathField)

        let browseHttpButton = NSButton(title: "Browse...", target: self, action: #selector(browseHttpPath))
        browseHttpButton.frame = NSRect(x: 470, y: yPosition, width: 70, height: 22)
        contentView.addSubview(browseHttpButton)

        yPosition -= 40

        // === LAUNCHCTL SERVICES SECTION ===
        let separatorLine2 = NSBox()
        separatorLine2.frame = NSRect(x: 20, y: yPosition, width: 520, height: 1)
        separatorLine2.boxType = .separator
        contentView.addSubview(separatorLine2)

        yPosition -= 25

        let servicesHeader = NSTextField(labelWithString: "Launchctl Services")
        servicesHeader.frame = NSRect(x: 20, y: yPosition, width: 520, height: 20)
        servicesHeader.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(servicesHeader)

        yPosition -= 10

        let servicesDesc = NSTextField(labelWithString: "Custom services managed via launchctl")
        servicesDesc.frame = NSRect(x: 20, y: yPosition, width: 520, height: 16)
        servicesDesc.font = NSFont.systemFont(ofSize: 11)
        servicesDesc.textColor = .secondaryLabelColor
        contentView.addSubview(servicesDesc)

        yPosition -= 25

        // Services table
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 20, y: 140, width: 520, height: yPosition - 140)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 120
        tableView.addTableColumn(nameColumn)

        let labelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        labelColumn.title = "Launchctl Label"
        labelColumn.width = 200
        tableView.addTableColumn(labelColumn)

        let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        categoryColumn.title = "Category"
        categoryColumn.width = 90
        tableView.addTableColumn(categoryColumn)

        let enabledColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledColumn.title = "Enabled"
        enabledColumn.width = 60
        tableView.addTableColumn(enabledColumn)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
        servicesTableView = tableView

        // Service buttons
        let addButton = NSButton(title: "+", target: self, action: #selector(addService))
        addButton.frame = NSRect(x: 20, y: 105, width: 30, height: 25)
        addButton.bezelStyle = .smallSquare
        contentView.addSubview(addButton)

        let removeButton = NSButton(title: "-", target: self, action: #selector(removeService))
        removeButton.frame = NSRect(x: 50, y: 105, width: 30, height: 25)
        removeButton.bezelStyle = .smallSquare
        contentView.addSubview(removeButton)

        let editButton = NSButton(title: "Edit", target: self, action: #selector(editService))
        editButton.frame = NSRect(x: 90, y: 105, width: 50, height: 25)
        editButton.bezelStyle = .smallSquare
        contentView.addSubview(editButton)

        // === GENERAL SETTINGS ===
        let separatorLine3 = NSBox()
        separatorLine3.frame = NSRect(x: 20, y: 90, width: 520, height: 1)
        separatorLine3.boxType = .separator
        contentView.addSubview(separatorLine3)

        killProcessCheckbox = NSButton(checkboxWithTitle: "Auto-terminate processes using same port", target: nil, action: nil)
        killProcessCheckbox?.frame = NSRect(x: 20, y: 60, width: 350, height: 20)
        killProcessCheckbox?.state = configuration.killExistingProcesses ? .on : .off
        contentView.addSubview(killProcessCheckbox!)

        let notificationsCheckbox = NSButton(checkboxWithTitle: "Show notifications", target: nil, action: nil)
        notificationsCheckbox.frame = NSRect(x: 380, y: 60, width: 160, height: 20)
        notificationsCheckbox.state = configuration.showNotifications ? .on : .off
        notificationsCheckbox.identifier = NSUserInterfaceItemIdentifier("notificationsCheckbox")
        contentView.addSubview(notificationsCheckbox)

        // Buttons
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 460, y: 15, width: 80, height: 30)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancelButton.frame = NSRect(x: 370, y: 15, width: 80, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)

        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 20, y: 15, width: 120, height: 30)
        contentView.addSubview(testButton)
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

    @objc func testConnection() {
        log(.info, "Testing connection with current settings")

        let testProcess = Process()
        testProcess.launchPath = "/bin/zsh"
        testProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) status"]

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
            log(.error, "Failed to test connection: \(error)")
            showError(message: "Failed to test connection: \(error.localizedDescription)")
        }
    }

    @objc func addService() {
        showServiceEditSheet(service: nil)
    }

    @objc func editService() {
        guard let tableView = servicesTableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < editingServices.count else {
            let alert = NSAlert()
            alert.messageText = "No Service Selected"
            alert.informativeText = "Please select a service to edit."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        showServiceEditSheet(service: editingServices[selectedRow])
    }

    @objc func removeService() {
        guard let tableView = servicesTableView else { return }
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < editingServices.count else {
            let alert = NSAlert()
            alert.messageText = "No Service Selected"
            alert.informativeText = "Please select a service to remove."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let service = editingServices[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Remove Service?"
        alert.informativeText = "Are you sure you want to remove \"\(service.name)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            editingServices.remove(at: selectedRow)
            tableView.reloadData()
        }
    }

    private func showServiceEditSheet(service: LaunchctlService?) {
        guard let parentWindow = settingsWindow else { return }

        let isEditing = service != nil
        let editingService = service ?? LaunchctlService(name: "", launchctlLabel: "")

        serviceEditWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        serviceEditWindow?.title = isEditing ? "Edit Service" : "Add Service"

        guard let contentView = serviceEditWindow?.contentView else { return }

        var yPosition: CGFloat = 280

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(nameLabel)

        let nameField = NSTextField()
        nameField.frame = NSRect(x: 130, y: yPosition, width: 300, height: 22)
        nameField.stringValue = editingService.name
        nameField.identifier = NSUserInterfaceItemIdentifier("editNameField")
        nameField.placeholderString = "My Service"
        contentView.addSubview(nameField)

        yPosition -= 35

        let labelLabel = NSTextField(labelWithString: "Launchctl Label:")
        labelLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(labelLabel)

        let labelField = NSTextField()
        labelField.frame = NSRect(x: 130, y: yPosition, width: 300, height: 22)
        labelField.stringValue = editingService.launchctlLabel
        labelField.identifier = NSUserInterfaceItemIdentifier("editLabelField")
        labelField.placeholderString = "com.example.myservice"
        contentView.addSubview(labelField)

        yPosition -= 35

        let portLabel = NSTextField(labelWithString: "Port (optional):")
        portLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(portLabel)

        let portField = NSTextField()
        portField.frame = NSRect(x: 130, y: yPosition, width: 80, height: 22)
        portField.stringValue = editingService.port.map { String($0) } ?? ""
        portField.identifier = NSUserInterfaceItemIdentifier("editPortField")
        portField.placeholderString = "8080"
        contentView.addSubview(portField)

        yPosition -= 35

        let categoryLabel = NSTextField(labelWithString: "Category:")
        categoryLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(categoryLabel)

        let categoryPopup = NSPopUpButton(frame: NSRect(x: 130, y: yPosition - 2, width: 150, height: 26))
        for category in ServiceCategory.allCases {
            categoryPopup.addItem(withTitle: category.displayName)
        }
        categoryPopup.selectItem(withTitle: editingService.category.displayName)
        categoryPopup.identifier = NSUserInterfaceItemIdentifier("editCategoryPopup")
        contentView.addSubview(categoryPopup)

        yPosition -= 40

        let descLabel = NSTextField(labelWithString: "Description:")
        descLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(descLabel)

        let descField = NSTextField()
        descField.frame = NSRect(x: 130, y: yPosition - 30, width: 300, height: 50)
        descField.stringValue = editingService.description
        descField.identifier = NSUserInterfaceItemIdentifier("editDescField")
        descField.placeholderString = "Description"
        contentView.addSubview(descField)

        yPosition -= 70

        let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled (show in menu)", target: nil, action: nil)
        enabledCheckbox.frame = NSRect(x: 130, y: yPosition, width: 200, height: 20)
        enabledCheckbox.state = editingService.isEnabled ? .on : .off
        enabledCheckbox.identifier = NSUserInterfaceItemIdentifier("editEnabledCheckbox")
        contentView.addSubview(enabledCheckbox)

        let saveEditButton = NSButton(title: isEditing ? "Save" : "Add", target: nil, action: nil)
        saveEditButton.frame = NSRect(x: 350, y: 10, width: 80, height: 30)
        saveEditButton.keyEquivalent = "\r"
        saveEditButton.target = self
        saveEditButton.action = #selector(saveServiceEdit(_:))
        saveEditButton.tag = isEditing ? 1 : 0
        contentView.addSubview(saveEditButton)

        let cancelEditButton = NSButton(title: "Cancel", target: self, action: #selector(cancelServiceEdit))
        cancelEditButton.frame = NSRect(x: 260, y: 10, width: 80, height: 30)
        cancelEditButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelEditButton)

        serviceEditWindow?.representedFilename = editingService.id.uuidString

        parentWindow.beginSheet(serviceEditWindow!) { _ in }
    }

    @objc func saveServiceEdit(_ sender: NSButton) {
        guard let editWindow = serviceEditWindow,
              let contentView = editWindow.contentView else { return }

        let isEditing = sender.tag == 1

        guard let nameField = contentView.subviews.first(where: {
            ($0 as? NSTextField)?.identifier?.rawValue == "editNameField"
        }) as? NSTextField else { return }

        guard let labelField = contentView.subviews.first(where: {
            ($0 as? NSTextField)?.identifier?.rawValue == "editLabelField"
        }) as? NSTextField else { return }

        guard let portField = contentView.subviews.first(where: {
            ($0 as? NSTextField)?.identifier?.rawValue == "editPortField"
        }) as? NSTextField else { return }

        guard let categoryPopup = contentView.subviews.first(where: {
            ($0 as? NSPopUpButton)?.identifier?.rawValue == "editCategoryPopup"
        }) as? NSPopUpButton else { return }

        guard let descField = contentView.subviews.first(where: {
            ($0 as? NSTextField)?.identifier?.rawValue == "editDescField"
        }) as? NSTextField else { return }

        guard let enabledCheckbox = contentView.subviews.first(where: {
            ($0 as? NSButton)?.identifier?.rawValue == "editEnabledCheckbox"
        }) as? NSButton else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let label = labelField.stringValue.trimmingCharacters(in: .whitespaces)

        if name.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Name Required"
            alert.informativeText = "Please enter a name for the service."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        if label.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Label Required"
            alert.informativeText = "Please enter the launchctl label."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let port: Int?
        let portString = portField.stringValue.trimmingCharacters(in: .whitespaces)
        if portString.isEmpty {
            port = nil
        } else if let portValue = Int(portString), portValue > 0 && portValue <= 65535 {
            port = portValue
        } else {
            let alert = NSAlert()
            alert.messageText = "Invalid Port"
            alert.informativeText = "Port must be 1-65535 or empty."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let categoryTitle = categoryPopup.selectedItem?.title ?? "General"
        let category = ServiceCategory.allCases.first { $0.displayName == categoryTitle } ?? .general

        if isEditing {
            let serviceIdString = editWindow.representedFilename
            if !serviceIdString.isEmpty,
               let serviceId = UUID(uuidString: serviceIdString),
               let index = editingServices.firstIndex(where: { $0.id == serviceId }) {
                editingServices[index].name = name
                editingServices[index].launchctlLabel = label
                editingServices[index].port = port
                editingServices[index].category = category
                editingServices[index].description = descField.stringValue
                editingServices[index].isEnabled = enabledCheckbox.state == .on
            }
        } else {
            let newService = LaunchctlService(
                name: name,
                launchctlLabel: label,
                port: port,
                description: descField.stringValue,
                category: category,
                isEnabled: enabledCheckbox.state == .on
            )
            editingServices.append(newService)
        }

        settingsWindow?.endSheet(editWindow)
        serviceEditWindow = nil
        servicesTableView?.reloadData()
    }

    @objc func cancelServiceEdit() {
        guard let editWindow = serviceEditWindow else { return }
        settingsWindow?.endSheet(editWindow)
        serviceEditWindow = nil
    }

    @objc func saveSettings() {
        // Save Teleport settings
        if let proxyField = settingsFields.first(where: { $0.identifier?.rawValue == "proxyField" }) {
            configuration.teleport.teleportProxy = proxyField.stringValue
        }
        if let hostField = settingsFields.first(where: { $0.identifier?.rawValue == "hostField" }) {
            configuration.teleport.jumpboxHost = hostField.stringValue
        }
        if let portField = settingsFields.first(where: { $0.identifier?.rawValue == "portField" }) {
            configuration.teleport.localPort = portField.stringValue
        }
        if let pathField = settingsFields.first(where: { $0.identifier?.rawValue == "pathField" }) {
            configuration.teleport.tshPath = pathField.stringValue
        }

        // Save HTTP proxy settings
        if let httpEnabledCheckbox = settingsWindow?.contentView?.subviews.first(where: {
            ($0 as? NSButton)?.identifier?.rawValue == "httpEnabledCheckbox"
        }) as? NSButton {
            configuration.httpProxy.enabled = httpEnabledCheckbox.state == .on
        }
        if let httpPortField = settingsFields.first(where: { $0.identifier?.rawValue == "httpPortField" }) {
            configuration.httpProxy.port = httpPortField.stringValue
        }
        if let httpPathField = settingsFields.first(where: { $0.identifier?.rawValue == "httpPathField" }) {
            configuration.httpProxy.path = httpPathField.stringValue
        }

        // Save general settings
        configuration.killExistingProcesses = killProcessCheckbox?.state == .on

        if let notificationsCheckbox = settingsWindow?.contentView?.subviews.first(where: {
            ($0 as? NSButton)?.identifier?.rawValue == "notificationsCheckbox"
        }) as? NSButton {
            configuration.showNotifications = notificationsCheckbox.state == .on
        }

        // Save launchctl services
        configuration.services = editingServices

        saveConfiguration()
        rebuildMenu()
        refreshAllStatuses()

        settingsWindow?.close()
        settingsWindow = nil

        showNotification(title: "Settings Saved", message: "Configuration has been updated")
    }

    @objc func cancelSettings() {
        settingsWindow?.close()
        settingsWindow = nil
    }

    // MARK: - Logs Window

    @objc func showLogs() {
        if logsWindow == nil {
            createLogsWindow()
        }
        updateLogsWindow()
        logsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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

        let clearButton = NSButton(title: "Clear Logs", target: self, action: #selector(clearLogs))
        clearButton.frame = NSRect(x: 20, y: 10, width: 100, height: 25)
        logsWindow?.contentView?.addSubview(clearButton)

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

    @objc func clearLogs() {
        logEntries.removeAll()
        updateLogsWindow()
        log(.info, "Logs cleared")
    }

    @objc func exportLogs() {
        let savePanel = NSSavePanel()
        if #available(macOS 11.0, *) {
            savePanel.allowedContentTypes = [.plainText]
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        savePanel.nameFieldStringValue = "infraproxy-logs-\(formatter.string(from: Date())).txt"

        if savePanel.runModal() == .OK {
            if let url = savePanel.url {
                let logFormatter = DateFormatter()
                logFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

                let logText = logEntries.map { entry in
                    "[\(logFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue)] \(entry.message)"
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
}

// MARK: - NSTableViewDataSource
extension InfraProxyManager: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return editingServices.count
    }
}

// MARK: - NSTableViewDelegate
extension InfraProxyManager: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < editingServices.count else { return nil }
        let service = editingServices[row]

        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        let cellIdentifier = NSUserInterfaceItemIdentifier("Cell_\(identifier.rawValue)")

        var textField: NSTextField

        if let existingView = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTextField {
            textField = existingView
        } else {
            textField = NSTextField()
            textField.identifier = cellIdentifier
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.isEditable = false
        }

        switch identifier.rawValue {
        case "name":
            textField.stringValue = service.name
        case "label":
            textField.stringValue = service.launchctlLabel
        case "category":
            textField.stringValue = service.category.displayName
        case "enabled":
            textField.stringValue = service.isEnabled ? "Yes" : "No"
        default:
            textField.stringValue = ""
        }

        return textField
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
