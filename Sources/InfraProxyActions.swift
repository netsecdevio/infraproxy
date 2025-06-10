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
        
        configuration.killExistingProcesses = defaults.bool(forKey: "killExistingProcesses")
        
        log(.info, "Configuration loaded: \(configuration.teleportProxy), \(configuration.jumpboxHost), port \(configuration.localPort)")
    }
    
    internal func saveConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(configuration.teleportProxy, forKey: "teleportProxy")
        defaults.set(configuration.jumpboxHost, forKey: "jumpboxHost")
        defaults.set(configuration.localPort, forKey: "localPort")
        defaults.set(configuration.tshPath, forKey: "tshPath")
        defaults.set(configuration.killExistingProcesses, forKey: "killExistingProcesses")
        
        log(.info, "Configuration saved")
    }
    
    // MARK: - Proxy Actions
    @objc func startProxy() {
        guard !isRunning else { return }
        
        if !isConfigurationValid() {
            showConfigurationError()
            return
        }
        
        if !handlePortContention() {
            log(.error, "Cannot start IA Proxy due to port contention")
            return
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
            self?.updateMenuState()
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
    
    @objc func checkPortUsage() {
        let pids = checkPortContention()
        
        let alert = NSAlert()
        alert.messageText = "Port \(configuration.localPort) Status"
        
        if pids.isEmpty {
            alert.informativeText = "✅ Port \(configuration.localPort) is available"
            alert.alertStyle = .informational
        } else {
            alert.informativeText = "⚠️ Port \(configuration.localPort) is in use by processes: \(pids.map(String.init).joined(separator: ", "))"
            alert.alertStyle = .warning
        }
        
        alert.runModal()
    }
    
    @objc func testConnection() {
        log(.info, "Testing connection with current settings")
        
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
            log(.error, "Failed to test connection: \(error)")
            showError(message: "Failed to test connection: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Teleport Actions
    @objc func loginToTeleport() {
        log(.info, "Manual login requested")
        
        let alert = NSAlert()
        alert.messageText = "Teleport Login"
        alert.informativeText = """
        To login to Teleport manually, run this command in Terminal:
        
        \(configuration.tshPath) login --proxy \(configuration.teleportProxy)
        
        After completing the browser login, the IA Proxy will be able to connect.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "OK")
        
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(configuration.tshPath) login --proxy \(configuration.teleportProxy)", forType: .string)
            showNotification(title: "Copied", message: "Login command copied to clipboard")
        case .alertSecondButtonReturn:
            if #available(macOS 11.0, *) {
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.launchApplication("Terminal")
            }
        default:
            break
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
            log(.error, "Failed to list servers: \(error)")
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
        log(.info, "Logs cleared")
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
    internal func showServerList(_ serverList: String) {
        let alert = NSAlert()
        alert.messageText = "Available Teleport Servers"
        alert.informativeText = serverList.isEmpty ? "No servers found or not logged in." : serverList
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    internal func createSettingsWindow() {
        if settingsWindow != nil {
            settingsWindow?.close()
            settingsWindow = nil
        }
        
        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "InfraProxy Settings"
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false
        
        settingsFields.removeAll()
        
        guard let contentView = settingsWindow?.contentView else { return }
        
        var yPosition: CGFloat = 430
        
        // Header
        let headerLabel = NSTextField(labelWithString: "Identity Aware (IA) Proxy Configuration")
        headerLabel.frame = NSRect(x: 20, y: yPosition, width: 460, height: 20)
        headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(headerLabel)
        
        yPosition -= 40
        
        // Teleport Proxy
        let proxyLabel = NSTextField(labelWithString: "Teleport Proxy:")
        proxyLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(proxyLabel)
        
        let proxyField = NSTextField()
        proxyField.frame = NSRect(x: 150, y: yPosition, width: 320, height: 22)
        proxyField.stringValue = configuration.teleportProxy
        proxyField.identifier = NSUserInterfaceItemIdentifier("proxyField")
        proxyField.isEditable = true
        proxyField.isSelectable = true
        proxyField.placeholderString = "teleport.example.com"
        contentView.addSubview(proxyField)
        settingsFields.append(proxyField)
        
        yPosition -= 40
        
        // Jumpbox Host
        let hostLabel = NSTextField(labelWithString: "Jumpbox Host:")
        hostLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(hostLabel)
        
        let hostField = NSTextField()
        hostField.frame = NSRect(x: 150, y: yPosition, width: 320, height: 22)
        hostField.stringValue = configuration.jumpboxHost
        hostField.identifier = NSUserInterfaceItemIdentifier("hostField")
        hostField.isEditable = true
        hostField.isSelectable = true
        hostField.placeholderString = "myjumpserver.example.com"
        contentView.addSubview(hostField)
        settingsFields.append(hostField)
        
        yPosition -= 40
        
        // Local Port
        let portLabel = NSTextField(labelWithString: "Local Port:")
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
        
        yPosition -= 40
        
        // TSH Path
        let pathLabel = NSTextField(labelWithString: "TSH Path:")
        pathLabel.frame = NSRect(x: 20, y: yPosition, width: 120, height: 20)
        contentView.addSubview(pathLabel)
        
        let pathField = NSTextField()
        pathField.frame = NSRect(x: 150, y: yPosition, width: 250, height: 22)
        pathField.stringValue = configuration.tshPath
        pathField.identifier = NSUserInterfaceItemIdentifier("pathField")
        pathField.isEditable = true
        pathField.isSelectable = true
        contentView.addSubview(pathField)
        settingsFields.append(pathField)
        
        let browseButton = NSButton(title: "Browse...", target: self, action: #selector(browseTshPath))
        browseButton.frame = NSRect(x: 410, y: yPosition, width: 70, height: 22)
        contentView.addSubview(browseButton)
        
        yPosition -= 60
        
        // Port Management section
        let portManagementLabel = NSTextField(labelWithString: "Port Management")
        portManagementLabel.frame = NSRect(x: 20, y: yPosition, width: 460, height: 20)
        portManagementLabel.font = NSFont.boldSystemFont(ofSize: 12)
        contentView.addSubview(portManagementLabel)
        
        yPosition -= 30
        
        // Kill existing processes checkbox
        killProcessCheckbox = NSButton(checkboxWithTitle: "Automatically terminate processes using the same port", target: nil, action: nil)
        killProcessCheckbox?.frame = NSRect(x: 20, y: yPosition, width: 400, height: 20)
        killProcessCheckbox?.state = configuration.killExistingProcesses ? .on : .off
        contentView.addSubview(killProcessCheckbox!)
        
        yPosition -= 30
        
        let warningLabel = NSTextField(labelWithString: "⚠️ Warning: This will forcefully terminate other processes using the configured port")
        warningLabel.frame = NSRect(x: 20, y: yPosition, width: 460, height: 20)
        warningLabel.font = NSFont.systemFont(ofSize: 10)
        warningLabel.textColor = .systemOrange
        contentView.addSubview(warningLabel)
        
        yPosition -= 60
        
        // Save/Cancel buttons
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 400, y: 20, width: 80, height: 30)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)
        
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancelButton.frame = NSRect(x: 310, y: 20, width: 80, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)
        
        // Test connection button
        let testButton = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        testButton.frame = NSRect(x: 20, y: 20, width: 120, height: 30)
        contentView.addSubview(testButton)
        
        // Check port button
        let checkPortButton = NSButton(title: "Check Port", target: self, action: #selector(checkPortUsage))
        checkPortButton.frame = NSRect(x: 150, y: 20, width: 100, height: 30)
        contentView.addSubview(checkPortButton)
    }
    
    internal func createLogsWindow() {
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
    
    internal func updateLogsWindow() {
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
