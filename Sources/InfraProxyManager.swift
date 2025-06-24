import Cocoa
import Foundation
import UserNotifications

class InfraProxyManager: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu!
    internal var socksProcess: Process?
    internal var isRunning = false
    
    // Configuration and logging
    internal var configuration = ProxyConfiguration()
    internal var logEntries: [LogEntry] = []
    internal let maxLogEntries = 1000
    
    // Windows and UI references
    internal var settingsWindow: NSWindow?
    internal var logsWindow: NSWindow?
    internal var settingsFields: [NSTextField] = []
    internal var killProcessCheckbox: NSButton?
    
    // Prevent rapid menu updates and control error popups
    private var lastMenuUpdate: Date = Date.distantPast
    private let menuUpdateThrottle: TimeInterval = 0.1
    private var suppressErrorPopups: Bool = false
    
    // Animation state
    private var isAnimating: Bool = false
    private var animationTimer: Timer?
    
    internal var httpProxyProcess: Process?
    internal var isHttpProxyRunning = false
    
    override init() {
        super.init()
        loadConfiguration()
        setupMenuBar()
        updateMenuState()
        log(.info, "InfraProxy started")
    }
    
    // MARK: - Menu Bar Setup
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
            button.image?.size = NSSize(width: 18, height: 18)
        }
        
        menu = NSMenu()
        
        // IA Proxy controls (existing)
        let startItem = NSMenuItem(title: "Start IA Proxy", action: #selector(startProxy), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop IA Proxy", action: #selector(stopProxy), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "Restart IA Proxy", action: #selector(restartProxy), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        // HTTP Proxy submenu (NEW)
        let httpProxyItem = NSMenuItem(title: "HTTP Proxy", action: nil, keyEquivalent: "")
        let httpProxySubmenu = NSMenu()

        let startHttpItem = NSMenuItem(title: "Start HTTP Proxy", action: #selector(startHttpProxy), keyEquivalent: "")
        startHttpItem.target = self
        httpProxySubmenu.addItem(startHttpItem)

        let stopHttpItem = NSMenuItem(title: "Stop HTTP Proxy", action: #selector(stopHttpProxy), keyEquivalent: "")
        stopHttpItem.target = self
        httpProxySubmenu.addItem(stopHttpItem)

        let restartHttpItem = NSMenuItem(title: "Restart HTTP Proxy", action: #selector(restartHttpProxy), keyEquivalent: "")
        restartHttpItem.target = self
        httpProxySubmenu.addItem(restartHttpItem)

        httpProxyItem.submenu = httpProxySubmenu
        menu.addItem(httpProxyItem)

        menu.addItem(NSMenuItem.separator())
        
        // Login management (PRESERVED)
        let loginItem = NSMenuItem(title: "Login to Teleport", action: #selector(loginToTeleport), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let statusCheckItem = NSMenuItem(title: "Check Status", action: #selector(checkTeleportStatus), keyEquivalent: "")
        statusCheckItem.target = self
        menu.addItem(statusCheckItem)

        menu.addItem(NSMenuItem.separator())
        
        // Configuration and logging
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        
        let logsItem = NSMenuItem(title: "Show Logs...", action: #selector(showLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)
        
        let listServersItem = NSMenuItem(title: "List Available Servers", action: #selector(listServers), keyEquivalent: "")
        listServersItem.target = self
        menu.addItem(listServersItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Status display
        let statusMenuItem = NSMenuItem(title: "Status: Stopped", action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit InfraProxy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        
        statusItem?.menu = menu
    }
    
    internal func updateMenuState() {
        let now = Date()
        guard now.timeIntervalSince(lastMenuUpdate) >= menuUpdateThrottle else { return }
        lastMenuUpdate = now
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let statusMenuItem = self.menu.item(withTag: 100) {
                var statusText = "Status: "
                if self.isRunning {
                    statusText += "IA Proxy running on localhost:\(self.configuration.localPort)"
                } else {
                    statusText += "IA Proxy stopped"
                }
                
                if self.configuration.httpProxyEnabled {
                    if self.isHttpProxyRunning {
                        statusText += " | HTTP Proxy running on localhost:\(self.configuration.httpProxyPort)"
                    } else {
                        statusText += " | HTTP Proxy stopped"
                    }
                }
                
                statusMenuItem.title = statusText
            }
            
            if let button = self.statusItem?.button {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
                button.image?.size = NSSize(width: 18, height: 18)
                
                if self.isRunning {
                    button.image = button.image?.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
                    )
                } else {
                    button.image = button.image?.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                    )
                }
            }
            
            self.menu.item(withTitle: "Start IA Proxy")?.isEnabled = !self.isRunning
            self.menu.item(withTitle: "Stop IA Proxy")?.isEnabled = self.isRunning
            self.menu.item(withTitle: "Restart IA Proxy")?.isEnabled = self.isRunning
            
            // Update HTTP proxy menu items if they exist
            if let httpSubmenu = self.menu.item(withTitle: "HTTP Proxy")?.submenu {
                httpSubmenu.item(withTitle: "Start")?.isEnabled = !self.isHttpProxyRunning && self.configuration.httpProxyEnabled
                httpSubmenu.item(withTitle: "Stop")?.isEnabled = self.isHttpProxyRunning
                httpSubmenu.item(withTitle: "Restart")?.isEnabled = self.isHttpProxyRunning
            }
            
            self.updateLoginStatusAsync()
        }
    }
    
    private func updateLoginStatusAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkTshStatusQuick { isLoggedIn in
                DispatchQueue.main.async { [weak self] in
                    self?.menu.item(withTitle: "Login to Teleport")?.title = isLoggedIn ? "✅ Logged into Teleport" : "Login to Teleport"
                }
            }
        }
    }
    
    // MARK: - Port Management
    internal func checkPortContention() -> [Int32] {
        var allPids: [Int32] = []
        
        // Check SOCKS port
        let socksPort = configuration.localPort
        let socksPids = checkPortContentionForPort(socksPort)
        allPids.append(contentsOf: socksPids)
        
        // Check HTTP proxy port if enabled
        if configuration.httpProxyEnabled {
            let httpPort = configuration.httpProxyPort
            let httpPids = checkPortContentionForPort(httpPort)
            allPids.append(contentsOf: httpPids)
        }
        
        return allPids
    }

    // Add this new helper method to InfraProxyManager.swift
    private func checkPortContentionForPort(_ port: String) -> [Int32] {
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
            log(.warning, "Failed to check port contention for port \(port): \(error.localizedDescription)")
        }
        
        return pids
    }
    
    internal func killProcesses(_ pids: [Int32]) {
        for pid in pids {
            let killProcess = Process()
            killProcess.launchPath = "/bin/kill"
            killProcess.arguments = ["-TERM", "\(pid)"]
            
            do {
                try killProcess.run()
                killProcess.waitUntilExit()
                
                if killProcess.terminationStatus == 0 {
                    log(.info, "Terminated process \(pid) using port \(configuration.localPort)")
                } else {
                    log(.warning, "Failed to terminate process \(pid)")
                }
            } catch {
                log(.error, "Failed to kill process \(pid): \(error.localizedDescription)")
            }
        }
        
        Thread.sleep(forTimeInterval: 1.0)
    }
    
    internal func handlePortContention() -> Bool {
        let conflictingPids = checkPortContention()
        
        if conflictingPids.isEmpty {
            return true
        }
        
        log(.warning, "Port \(configuration.localPort) is in use by processes: \(conflictingPids)")
        
        if configuration.killExistingProcesses {
            log(.info, "Killing existing processes on port \(configuration.localPort)")
            killProcesses(conflictingPids)
            
            let remainingPids = checkPortContention()
            if !remainingPids.isEmpty {
                log(.error, "Some processes could not be terminated: \(remainingPids)")
                showError(message: "Port \(configuration.localPort) is still in use by processes: \(remainingPids.map(String.init).joined(separator: ", "))")
                return false
            }
            return true
        } else {
            return showPortContentionDialog(pids: conflictingPids)
        }
    }
    
    internal func showPortContentionDialog(pids: [Int32]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Port Contention Detected"
        
        var conflictDetails = "The following ports are in use:\n"
        
        let socksPids = checkPortContentionForPort(configuration.localPort)
        if !socksPids.isEmpty {
            conflictDetails += "• SOCKS Port \(configuration.localPort): PIDs \(socksPids.map(String.init).joined(separator: ", "))\n"
        }
        
        if configuration.httpProxyEnabled {
            let httpPids = checkPortContentionForPort(configuration.httpProxyPort)
            if !httpPids.isEmpty {
                conflictDetails += "• HTTP Port \(configuration.httpProxyPort): PIDs \(httpPids.map(String.init).joined(separator: ", "))\n"
            }
        }
        
        alert.informativeText = conflictDetails + "\nWould you like to terminate these processes and continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Terminate & Continue")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            killProcesses(pids)
            return checkPortContention().isEmpty
        }
        return false
    }
    
    // MARK: - Logging
    internal func log(_ level: LogEntry.LogLevel, _ message: String) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message)
        logEntries.append(entry)
        
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        
        print("[\(level.rawValue)] \(message)")
    }
    
    // MARK: - Helper Methods
    internal func showNotification(title: String, message: String) {
        if #available(macOS 10.14, *) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = message
            content.sound = UNNotificationSound.default
            
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        } else {
            let notification = NSUserNotification()
            notification.title = title
            notification.informativeText = message
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
        }
    }
    
    internal func showError(message: String) {
        if suppressErrorPopups {
            log(.error, "Error (popup suppressed): \(message)")
            return
        }
        
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }
    }
}

// Extension for @objc methods will be in the next file
extension InfraProxyManager {
    @objc func quitApp() {
        stopWaitingAnimation()
        
        if isRunning {
            stopProxy()
        }
        NSApplication.shared.terminate(nil)
    }
    
    private func stopWaitingAnimation() {
        guard isAnimating else { return }
        
        isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil
        
        updateMenuState()
    }
    
    // MARK: - Helper Methods
    internal func isConfigurationValid() -> Bool {
        return !configuration.teleportProxy.isEmpty &&
               !configuration.jumpboxHost.isEmpty &&
               !configuration.localPort.isEmpty &&
               !configuration.tshPath.isEmpty &&
               Int(configuration.localPort) != nil &&
               Int(configuration.localPort)! > 0 &&
               Int(configuration.localPort)! < 65536
    }
    
    internal func showConfigurationError() {
        let alert = NSAlert()
        alert.messageText = "Configuration Required"
        alert.informativeText = """
        Please configure the IA Proxy settings before starting.
        
        Go to Settings and provide:
        - Teleport Proxy server
        - Jumpbox Host
        - Valid local port (1-65535)
        - TSH executable path
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        
        if alert.runModal() == .alertFirstButtonReturn {
            showSettings()
        }
    }
    
    internal func startSocksProcess() {
        log(.info, "Already logged in, starting SOCKS directly")
        
        socksProcess = Process()
        socksProcess?.launchPath = "/bin/zsh"
        socksProcess?.arguments = ["-l", "-c", "\(configuration.tshPath) ssh -A -N -D \(configuration.localPort) \(configuration.jumpboxHost)"]
        
        startProcessWithMonitoring()
    }
    
    internal func startBackgroundLoginAndSocks() {
        log(.info, "Not logged in, starting login process")
        
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
                    self?.showNotification(title: "Login Successful", message: "Login completed, starting IA Proxy...")
                    self?.waitForLoginCompletionAndStartProxy()
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
    
    private func waitForLoginCompletionAndStartProxy() {
        log(.info, "Login process closed, waiting for credentials to be fully available...")
        
        DispatchQueue.main.async { [weak self] in
            self?.startWaitingAnimation()
        }
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.waitForCredentialsWithRetry()
        }
    }
    
    private func waitForCredentialsWithRetry() {
        log(.info, "Starting credential availability check...")
        
        DispatchQueue.main.async { [weak self] in
            self?.suppressErrorPopups = true
        }
        
        let maxAttempts = 6
        let delays: [TimeInterval] = [3, 5, 7, 10, 12, 15]
        
        for attempt in 0..<maxAttempts {
            let delay = delays[attempt]
            
            log(.info, "Attempt \(attempt + 1)/\(maxAttempts): Waiting \(Int(delay)) seconds...")
            Thread.sleep(forTimeInterval: delay)
            
            let credentialsReady = checkCredentialsSync()
            
            if credentialsReady {
                log(.info, "Credentials verified as working after \(Int(delays[0...attempt].reduce(0, +))) total seconds")
                DispatchQueue.main.async { [weak self] in
                    self?.stopWaitingAnimation()
                    self?.log(.info, "Simulating manual 'Start IA Proxy' button click")
                    self?.startProxy()
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                        self?.suppressErrorPopups = false
                        self?.log(.info, "Error popups re-enabled")
                    }
                }
                return
            } else {
                log(.warning, "Credentials not ready yet on attempt \(attempt + 1)")
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.stopWaitingAnimation()
            self?.suppressErrorPopups = false
            self?.log(.error, "Credentials still not available after all attempts")
            self?.showError(message: "Login completed but credentials are not available. Please try starting the IA Proxy manually.")
        }
    }
    
    private func checkCredentialsSync() -> Bool {
        let statusReady = checkBasicStatusSync()
        if !statusReady {
            return false
        }
        return checkSSHAccessSync()
    }
    
    private func checkBasicStatusSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isReady = false
        
        let statusProcess = Process()
        statusProcess.launchPath = "/bin/zsh"
        statusProcess.arguments = ["-l", "-c", "\(configuration.tshPath) status"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        statusProcess.environment = environment
        statusProcess.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let pipe = Pipe()
        statusProcess.standardOutput = pipe
        statusProcess.standardError = pipe
        
        statusProcess.terminationHandler = { process in
            let exitCode = process.terminationStatus
            isReady = (exitCode == 0)
            semaphore.signal()
        }
        
        do {
            try statusProcess.run()
            let result = semaphore.wait(timeout: .now() + 5)
            if result == .timedOut {
                statusProcess.terminate()
                return false
            }
            return isReady
        } catch {
            semaphore.signal()
            return false
        }
    }
    
    private func checkSSHAccessSync() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var isReady = false
        
        let sshTestProcess = Process()
        sshTestProcess.launchPath = "/bin/zsh"
        sshTestProcess.arguments = ["-l", "-c", "\(configuration.tshPath) ssh \(configuration.jumpboxHost) exit"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        sshTestProcess.environment = environment
        sshTestProcess.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let pipe = Pipe()
        sshTestProcess.standardOutput = pipe
        sshTestProcess.standardError = pipe
        
        sshTestProcess.terminationHandler = { process in
            let exitCode = process.terminationStatus
            isReady = (exitCode == 0)
            semaphore.signal()
        }
        
        do {
            try sshTestProcess.run()
            let result = semaphore.wait(timeout: .now() + 10)
            if result == .timedOut {
                sshTestProcess.terminate()
                return false
            }
            return isReady
        } catch {
            semaphore.signal()
            return false
        }
    }
    
    private func startProcessWithMonitoring() {
        guard let process = socksProcess else { return }
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        environment["PATH"] = "\(configuration.tshPath.replacingOccurrences(of: "/tsh", with: "")):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        process.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        let outputHandle = outputPipe.fileHandleForReading
        outputHandle.readabilityHandler = { [weak self] handle in
            DispatchQueue.global(qos: .background).async {
                let data = handle.availableData
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    DispatchQueue.main.async {
                        self?.log(.info, "Process output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        if output.contains("Starting Teleport login") {
                            self?.showNotification(title: "Login Started", message: "Browser authentication required")
                        } else if output.contains("Login successful") {
                            self?.showNotification(title: "Login Successful", message: "Starting IA Proxy...")
                        }
                    }
                }
            }
        }
        
        let errorHandle = errorPipe.fileHandleForReading
        errorHandle.readabilityHandler = { [weak self] handle in
            DispatchQueue.global(qos: .background).async {
                let data = handle.availableData
                if let errorString = String(data: data, encoding: .utf8), !errorString.isEmpty {
                    DispatchQueue.main.async {
                        self?.log(.error, "Process error: \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))")
                        
                        if errorString.contains("ERROR") && errorString.contains("access denied") {
                            if self?.suppressErrorPopups == false {
                                self?.showError(message: "IA Proxy Error: Authentication failed. Please check your Teleport login.")
                            } else {
                                self?.log(.error, "IA Proxy error suppressed during retry: Authentication failed")
                            }
                        }
                    }
                }
            }
        }
        
        process.terminationHandler = { [weak self] process in
            outputHandle.readabilityHandler = nil
            errorHandle.readabilityHandler = nil
            
            DispatchQueue.main.async {
                let exitCode = process.terminationStatus
                self?.log(.info, "Process terminated with exit code: \(exitCode)")
                
                self?.isRunning = false
                self?.updateMenuState()
                
                if exitCode == 0 {
                    self?.showNotification(title: "IA Proxy Stopped", message: "IA Proxy terminated normally")
                } else {
                    self?.log(.error, "IA Proxy failed with exit code: \(exitCode)")
                    self?.showNotification(title: "IA Proxy Error", message: "Process failed with exit code \(exitCode)")
                }
            }
        }
        
        do {
            try process.run()
            isRunning = true
            updateMenuState()
            log(.info, "Started IA Proxy process with PID: \(process.processIdentifier)")
            showNotification(title: "IA Proxy Starting", message: "InfraProxy process started")
        } catch {
            log(.error, "Failed to start IA Proxy process: \(error.localizedDescription)")
            showError(message: "Failed to start IA Proxy: \(error.localizedDescription)")
        }
    }
    
    func checkTshStatus(completion: @escaping (Bool) -> Void) {
        let statusProcess = Process()
        statusProcess.launchPath = "/bin/zsh"
        statusProcess.arguments = ["-l", "-c", "\(configuration.tshPath) status"]
        
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["USER"] = NSUserName()
        environment["SHELL"] = "/bin/zsh"
        statusProcess.environment = environment
        statusProcess.currentDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        
        let pipe = Pipe()
        statusProcess.standardOutput = pipe
        statusProcess.standardError = pipe
        
        statusProcess.terminationHandler = { process in
            DispatchQueue.main.async {
                completion(process.terminationStatus == 0)
            }
        }
        
        do {
            try statusProcess.run()
        } catch {
            completion(false)
        }
    }
    
    func checkTshStatusQuick(completion: @escaping (Bool) -> Void) {
        checkTshStatus(completion: completion)
    }
    
    private func startWaitingAnimation() {
        guard !isAnimating else { return }
        
        isAnimating = true
        var isVisible = true
        
        if let statusMenuItem = menu.item(withTag: 100) {
            statusMenuItem.title = "Status: Waiting for credentials..."
        }
        
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let button = self.statusItem?.button else { return }
            
            if isVisible {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
                button.image?.size = NSSize(width: 18, height: 18)
                button.image = button.image?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemOrange])
                )
            } else {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
                button.image?.size = NSSize(width: 18, height: 18)
                button.image = button.image?.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(paletteColors: [.systemGray])
                )
            }
            
            isVisible.toggle()
        }
    }
}
