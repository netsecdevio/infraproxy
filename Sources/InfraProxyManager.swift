import Cocoa
import Foundation
import UserNotifications

class InfraProxyManager: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu!

    // Teleport process management
    internal var socksProcess: Process?
    internal var isRunning = false

    // HTTP Proxy process management
    internal var httpProxyProcess: Process?
    internal var isHttpProxyRunning = false

    // Launchctl service management
    internal let launchctlManager = LaunchctlServiceManager()
    internal var serviceStatuses: [UUID: ServiceStatus] = [:]

    // Configuration
    internal var configuration = AppConfiguration()

    // Status refresh
    private var refreshTimer: Timer?
    private let statusRefreshInterval: TimeInterval = 5.0

    // Logging
    internal var logEntries: [LogEntry] = []
    internal let maxLogEntries = 1000

    // Windows and UI references
    internal var settingsWindow: NSWindow?
    internal var logsWindow: NSWindow?
    internal var serviceEditWindow: NSWindow?

    // Settings UI references
    internal var settingsFields: [NSTextField] = []
    internal var killProcessCheckbox: NSButton?
    internal var servicesTableView: NSTableView?
    internal var editingServices: [LaunchctlService] = []

    // Prevent rapid menu updates and control error popups
    private var lastMenuUpdate: Date = Date.distantPast
    private let menuUpdateThrottle: TimeInterval = 0.1
    private var suppressErrorPopups: Bool = false

    // Animation state
    private var isAnimating: Bool = false
    private var animationTimer: Timer?

    override init() {
        super.init()
        loadConfiguration()
        setupMenuBar()
        startStatusRefresh()
        log(.info, "InfraProxy started")
    }

    deinit {
        stopStatusRefresh()
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
            button.image?.size = NSSize(width: 18, height: 18)
        }

        menu = NSMenu()
        rebuildMenu()
        statusItem?.menu = menu
    }

    // MARK: - Dynamic Menu Generation

    internal func rebuildMenu() {
        menu.removeAllItems()

        // === TELEPORT SECTION ===
        let teleportHeader = NSMenuItem(title: "-- Teleport --", action: nil, keyEquivalent: "")
        teleportHeader.isEnabled = false
        teleportHeader.attributedTitle = NSAttributedString(
            string: "-- Teleport --",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        menu.addItem(teleportHeader)

        // IA Proxy controls
        let startItem = NSMenuItem(title: "Start IA Proxy", action: #selector(startProxy), keyEquivalent: "")
        startItem.target = self
        startItem.isEnabled = !isRunning
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop IA Proxy", action: #selector(stopProxy), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = isRunning
        menu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "Restart IA Proxy", action: #selector(restartProxy), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = isRunning
        menu.addItem(restartItem)

        menu.addItem(NSMenuItem.separator())

        // Login management
        let loginItem = NSMenuItem(title: "Login to Teleport", action: #selector(loginToTeleport), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let statusCheckItem = NSMenuItem(title: "Check Status", action: #selector(checkTeleportStatus), keyEquivalent: "")
        statusCheckItem.target = self
        menu.addItem(statusCheckItem)

        let listServersItem = NSMenuItem(title: "List Available Servers", action: #selector(listServers), keyEquivalent: "")
        listServersItem.target = self
        menu.addItem(listServersItem)

        menu.addItem(NSMenuItem.separator())

        // === HTTP PROXY SECTION ===
        let httpHeader = NSMenuItem(title: "-- HTTP Proxy --", action: nil, keyEquivalent: "")
        httpHeader.isEnabled = false
        httpHeader.attributedTitle = NSAttributedString(
            string: "-- HTTP Proxy --",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
        )
        menu.addItem(httpHeader)

        let startHttpItem = NSMenuItem(title: "Start HTTP Proxy", action: #selector(startHttpProxy), keyEquivalent: "")
        startHttpItem.target = self
        startHttpItem.isEnabled = !isHttpProxyRunning && configuration.httpProxy.enabled
        menu.addItem(startHttpItem)

        let stopHttpItem = NSMenuItem(title: "Stop HTTP Proxy", action: #selector(stopHttpProxy), keyEquivalent: "")
        stopHttpItem.target = self
        stopHttpItem.isEnabled = isHttpProxyRunning
        menu.addItem(stopHttpItem)

        let restartHttpItem = NSMenuItem(title: "Restart HTTP Proxy", action: #selector(restartHttpProxy), keyEquivalent: "")
        restartHttpItem.target = self
        restartHttpItem.isEnabled = isHttpProxyRunning
        menu.addItem(restartHttpItem)

        menu.addItem(NSMenuItem.separator())

        // === LAUNCHCTL SERVICES SECTION ===
        let enabledServices = configuration.services.filter { $0.isEnabled }

        if !enabledServices.isEmpty {
            let servicesHeader = NSMenuItem(title: "-- Launchctl Services --", action: nil, keyEquivalent: "")
            servicesHeader.isEnabled = false
            servicesHeader.attributedTitle = NSAttributedString(
                string: "-- Launchctl Services --",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
            )
            menu.addItem(servicesHeader)

            // Group services by category
            let groupedServices = Dictionary(grouping: enabledServices) { $0.category }
            let sortedCategories = groupedServices.keys.sorted { $0.sortOrder < $1.sortOrder }

            for category in sortedCategories {
                guard let services = groupedServices[category], !services.isEmpty else { continue }

                // Add category subheader
                let categoryItem = NSMenuItem(title: "  \(category.displayName)", action: nil, keyEquivalent: "")
                categoryItem.isEnabled = false
                menu.addItem(categoryItem)

                // Add service items
                for service in services.sorted(by: { $0.name < $1.name }) {
                    addServiceSubmenu(for: service)
                }
            }

            menu.addItem(NSMenuItem.separator())

            // Batch operations
            if enabledServices.count > 1 {
                let startAllItem = NSMenuItem(title: "Start All Services", action: #selector(startAllServices), keyEquivalent: "")
                startAllItem.target = self
                menu.addItem(startAllItem)

                let stopAllItem = NSMenuItem(title: "Stop All Services", action: #selector(stopAllServices), keyEquivalent: "")
                stopAllItem.target = self
                menu.addItem(stopAllItem)

                menu.addItem(NSMenuItem.separator())
            }
        }

        // === UTILITIES ===
        let checkPortsItem = NSMenuItem(title: "Check Ports", action: #selector(checkPortUsage), keyEquivalent: "")
        checkPortsItem.target = self
        menu.addItem(checkPortsItem)

        menu.addItem(NSMenuItem.separator())

        // Settings and logs
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logsItem = NSMenuItem(title: "Show Logs...", action: #selector(showLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        menu.addItem(NSMenuItem.separator())

        // Status display
        let statusMenuItem = NSMenuItem(title: getStatusSummary(), action: nil, keyEquivalent: "")
        statusMenuItem.tag = 100
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit InfraProxy", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuBarIcon()
        updateLoginStatusAsync()
    }

    private func addServiceSubmenu(for service: LaunchctlService) {
        let status = serviceStatuses[service.id] ?? .unknown
        let statusIndicator: String
        switch status {
        case .running: statusIndicator = "✅ "
        case .stopped: statusIndicator = "⏹ "
        case .notLoaded: statusIndicator = "❌ "
        case .unknown: statusIndicator = "❓ "
        }

        let submenuItem = NSMenuItem(title: "    \(statusIndicator)\(service.displayName)", action: nil, keyEquivalent: "")

        let submenu = NSMenu()

        let startItem = NSMenuItem(title: "Start", action: #selector(startServiceAction(_:)), keyEquivalent: "")
        startItem.representedObject = service
        startItem.target = self
        startItem.isEnabled = !status.isRunning
        submenu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopServiceAction(_:)), keyEquivalent: "")
        stopItem.representedObject = service
        stopItem.target = self
        stopItem.isEnabled = status.isRunning
        submenu.addItem(stopItem)

        let restartItem = NSMenuItem(title: "Restart", action: #selector(restartServiceAction(_:)), keyEquivalent: "")
        restartItem.representedObject = service
        restartItem.target = self
        submenu.addItem(restartItem)

        submenu.addItem(NSMenuItem.separator())

        let statusItem = NSMenuItem(title: "Status: \(status.displayString)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        submenu.addItem(statusItem)

        if !service.description.isEmpty {
            let descItem = NSMenuItem(title: service.description, action: nil, keyEquivalent: "")
            descItem.isEnabled = false
            submenu.addItem(descItem)
        }

        submenuItem.submenu = submenu
        menu.addItem(submenuItem)
    }

    private func getStatusSummary() -> String {
        var parts: [String] = []

        if isRunning {
            parts.append("IA Proxy: ✅")
        }
        if isHttpProxyRunning {
            parts.append("HTTP: ✅")
        }

        let enabledServices = configuration.services.filter { $0.isEnabled }
        let runningCount = enabledServices.filter { service in
            serviceStatuses[service.id]?.isRunning ?? false
        }.count

        if !enabledServices.isEmpty {
            parts.append("Services: \(runningCount)/\(enabledServices.count)")
        }

        if parts.isEmpty {
            return "Status: All stopped"
        }

        return "Status: " + parts.joined(separator: " | ")
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
        button.image?.size = NSSize(width: 18, height: 18)

        let enabledServices = configuration.services.filter { $0.isEnabled }
        let runningServicesCount = enabledServices.filter { service in
            serviceStatuses[service.id]?.isRunning ?? false
        }.count

        let anyRunning = isRunning || isHttpProxyRunning || runningServicesCount > 0
        let allRunning = (isRunning || !isTeleportConfigured()) &&
                        (isHttpProxyRunning || !configuration.httpProxy.enabled) &&
                        (runningServicesCount == enabledServices.count || enabledServices.isEmpty)

        let color: NSColor
        if isAnimating {
            color = .systemOrange
        } else if anyRunning && allRunning {
            color = .systemGreen
        } else if anyRunning {
            color = .systemOrange
        } else {
            color = .systemRed
        }

        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
    }

    private func isTeleportConfigured() -> Bool {
        return !configuration.teleport.teleportProxy.isEmpty &&
               configuration.teleport.teleportProxy != "teleport.example.com"
    }

    private func updateLoginStatusAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.checkTshStatusQuick { isLoggedIn in
                DispatchQueue.main.async { [weak self] in
                    if let loginItem = self?.menu.item(withTitle: "Login to Teleport") {
                        loginItem.title = isLoggedIn ? "✅ Logged into Teleport" : "Login to Teleport"
                    } else if let loginItem = self?.menu.item(withTitle: "✅ Logged into Teleport") {
                        loginItem.title = isLoggedIn ? "✅ Logged into Teleport" : "Login to Teleport"
                    }
                }
            }
        }
    }

    // MARK: - Status Refresh

    private func startStatusRefresh() {
        refreshAllStatuses()

        refreshTimer = Timer.scheduledTimer(withTimeInterval: statusRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshAllStatuses()
        }
    }

    private func stopStatusRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    internal func refreshAllStatuses() {
        for service in configuration.services {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self = self else { return }
                let status = self.launchctlManager.checkStatusSync(for: service)
                DispatchQueue.main.async {
                    let oldStatus = self.serviceStatuses[service.id]
                    self.serviceStatuses[service.id] = status

                    // Only rebuild menu if status changed
                    if oldStatus != status {
                        self.rebuildMenu()
                    }
                }
            }
        }
    }

    // MARK: - Port Management

    internal func checkPortContention() -> [Int32] {
        var allPids: [Int32] = []

        // Check SOCKS port
        let socksPort = configuration.teleport.localPort
        let socksPids = checkPortContentionForPort(socksPort)
        allPids.append(contentsOf: socksPids)

        // Check HTTP proxy port if enabled
        if configuration.httpProxy.enabled {
            let httpPort = configuration.httpProxy.port
            let httpPids = checkPortContentionForPort(httpPort)
            allPids.append(contentsOf: httpPids)
        }

        return allPids
    }

    internal func checkPortContentionForPort(_ port: String) -> [Int32] {
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
                    log(.info, "Terminated process \(pid)")
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

        log(.warning, "Port contention detected with processes: \(conflictingPids)")

        if configuration.killExistingProcesses {
            log(.info, "Killing existing processes")
            killProcesses(conflictingPids)

            let remainingPids = checkPortContention()
            if !remainingPids.isEmpty {
                log(.error, "Some processes could not be terminated: \(remainingPids)")
                showError(message: "Port still in use by processes: \(remainingPids.map(String.init).joined(separator: ", "))")
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

        let socksPids = checkPortContentionForPort(configuration.teleport.localPort)
        if !socksPids.isEmpty {
            conflictDetails += "• SOCKS Port \(configuration.teleport.localPort): PIDs \(socksPids.map(String.init).joined(separator: ", "))\n"
        }

        if configuration.httpProxy.enabled {
            let httpPids = checkPortContentionForPort(configuration.httpProxy.port)
            if !httpPids.isEmpty {
                conflictDetails += "• HTTP Port \(configuration.httpProxy.port): PIDs \(httpPids.map(String.init).joined(separator: ", "))\n"
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

    // MARK: - Teleport Status Checking

    func checkTshStatus(completion: @escaping (Bool) -> Void) {
        let statusProcess = Process()
        statusProcess.launchPath = "/bin/zsh"
        statusProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) status"]

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

    // MARK: - Teleport SOCKS Process

    internal func isConfigurationValid() -> Bool {
        return !configuration.teleport.teleportProxy.isEmpty &&
               !configuration.teleport.jumpboxHost.isEmpty &&
               !configuration.teleport.localPort.isEmpty &&
               !configuration.teleport.tshPath.isEmpty &&
               Int(configuration.teleport.localPort) != nil &&
               Int(configuration.teleport.localPort)! > 0 &&
               Int(configuration.teleport.localPort)! < 65536
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
        socksProcess?.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) ssh -A -N -D \(configuration.teleport.localPort) \(configuration.teleport.jumpboxHost)"]

        startProcessWithMonitoring()
    }

    internal func startBackgroundLoginAndSocks() {
        log(.info, "Not logged in, starting login process")

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
        statusProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) status"]

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
        sshTestProcess.arguments = ["-l", "-c", "\(configuration.teleport.tshPath) ssh \(configuration.teleport.jumpboxHost) exit"]

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
        environment["PATH"] = "\(configuration.teleport.tshPath.replacingOccurrences(of: "/tsh", with: "")):/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
                self?.rebuildMenu()

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
            rebuildMenu()
            log(.info, "Started IA Proxy process with PID: \(process.processIdentifier)")
            showNotification(title: "IA Proxy Starting", message: "InfraProxy process started")
        } catch {
            log(.error, "Failed to start IA Proxy process: \(error.localizedDescription)")
            showError(message: "Failed to start IA Proxy: \(error.localizedDescription)")
        }
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

    private func stopWaitingAnimation() {
        guard isAnimating else { return }

        isAnimating = false
        animationTimer?.invalidate()
        animationTimer = nil

        rebuildMenu()
    }

    // MARK: - Launchctl Service Actions

    @objc func startServiceAction(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? LaunchctlService else { return }
        startService(service)
    }

    @objc func stopServiceAction(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? LaunchctlService else { return }
        stopService(service)
    }

    @objc func restartServiceAction(_ sender: NSMenuItem) {
        guard let service = sender.representedObject as? LaunchctlService else { return }
        restartService(service)
    }

    internal func startService(_ service: LaunchctlService) {
        log(.info, "Starting service: \(service.name) (\(service.launchctlLabel))")

        launchctlManager.start(service: service) { [weak self] result in
            switch result {
            case .success:
                self?.log(.info, "Service started: \(service.name)")
                if self?.configuration.showNotifications ?? true {
                    self?.showNotification(title: "Service Started", message: "\(service.name) has been started")
                }
            case .failure(let error):
                self?.log(.error, "Failed to start service \(service.name): \(error.localizedDescription)")
                self?.showError(message: "Failed to start \(service.name): \(error.localizedDescription)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshAllStatuses()
            }
        }
    }

    internal func stopService(_ service: LaunchctlService) {
        log(.info, "Stopping service: \(service.name) (\(service.launchctlLabel))")

        launchctlManager.stop(service: service) { [weak self] result in
            switch result {
            case .success:
                self?.log(.info, "Service stopped: \(service.name)")
                if self?.configuration.showNotifications ?? true {
                    self?.showNotification(title: "Service Stopped", message: "\(service.name) has been stopped")
                }
            case .failure(let error):
                self?.log(.error, "Failed to stop service \(service.name): \(error.localizedDescription)")
                self?.showError(message: "Failed to stop \(service.name): \(error.localizedDescription)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self?.refreshAllStatuses()
            }
        }
    }

    internal func restartService(_ service: LaunchctlService) {
        log(.info, "Restarting service: \(service.name) (\(service.launchctlLabel))")

        launchctlManager.restart(service: service) { [weak self] result in
            switch result {
            case .success:
                self?.log(.info, "Service restarted: \(service.name)")
                if self?.configuration.showNotifications ?? true {
                    self?.showNotification(title: "Service Restarted", message: "\(service.name) has been restarted")
                }
            case .failure(let error):
                self?.log(.error, "Failed to restart service \(service.name): \(error.localizedDescription)")
                self?.showError(message: "Failed to restart \(service.name): \(error.localizedDescription)")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self?.refreshAllStatuses()
            }
        }
    }

    @objc func startAllServices() {
        log(.info, "Starting all services")
        let enabledServices = configuration.services.filter { $0.isEnabled }

        for service in enabledServices {
            let status = serviceStatuses[service.id] ?? .unknown
            if !status.isRunning {
                startService(service)
            }
        }
    }

    @objc func stopAllServices() {
        log(.info, "Stopping all services")
        let enabledServices = configuration.services.filter { $0.isEnabled }

        for service in enabledServices {
            let status = serviceStatuses[service.id] ?? .unknown
            if status.isRunning {
                stopService(service)
            }
        }
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
        guard configuration.showNotifications else { return }

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

    @objc func quitApp() {
        stopWaitingAnimation()
        stopStatusRefresh()

        if isRunning {
            stopProxy()
        }
        if isHttpProxyRunning {
            stopHttpProxy()
        }

        NSApplication.shared.terminate(nil)
    }
}
