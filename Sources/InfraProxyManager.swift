import Cocoa
import Foundation
import UserNotifications

class InfraProxyManager: NSObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu!

    // Service management
    internal let launchctlManager = LaunchctlServiceManager()
    internal var configuration = AppConfiguration()
    internal var serviceStatuses: [UUID: ServiceStatus] = [:]

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

    // Table view references for settings
    internal var servicesTableView: NSTableView?
    internal var editingServices: [LaunchctlService] = []

    // Prevent rapid menu updates
    private var lastMenuUpdate: Date = Date.distantPast
    private let menuUpdateThrottle: TimeInterval = 0.1

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

        let enabledServices = configuration.services.filter { $0.isEnabled }

        if enabledServices.isEmpty {
            let noServicesItem = NSMenuItem(title: "No services configured", action: nil, keyEquivalent: "")
            noServicesItem.isEnabled = false
            menu.addItem(noServicesItem)

            let addServiceItem = NSMenuItem(title: "Add service in Settings...", action: #selector(showSettings), keyEquivalent: "")
            addServiceItem.target = self
            menu.addItem(addServiceItem)
        } else {
            // Group services by category
            let groupedServices = Dictionary(grouping: enabledServices) { $0.category }

            // Sort categories by their defined order
            let sortedCategories = groupedServices.keys.sorted { $0.sortOrder < $1.sortOrder }

            for category in sortedCategories {
                guard let services = groupedServices[category], !services.isEmpty else { continue }

                // Add category header
                let headerItem = NSMenuItem(title: "-- \(category.displayName) --", action: nil, keyEquivalent: "")
                headerItem.isEnabled = false
                headerItem.attributedTitle = NSAttributedString(
                    string: "-- \(category.displayName) --",
                    attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]
                )
                menu.addItem(headerItem)

                // Add service items
                for service in services.sorted(by: { $0.name < $1.name }) {
                    addServiceSubmenu(for: service)
                }
            }

            menu.addItem(NSMenuItem.separator())

            // Batch operations
            if enabledServices.count > 1 {
                let startAllItem = NSMenuItem(title: "Start All", action: #selector(startAllServices), keyEquivalent: "")
                startAllItem.target = self
                menu.addItem(startAllItem)

                let stopAllItem = NSMenuItem(title: "Stop All", action: #selector(stopAllServices), keyEquivalent: "")
                stopAllItem.target = self
                menu.addItem(stopAllItem)

                menu.addItem(NSMenuItem.separator())
            }
        }

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

        let submenuItem = NSMenuItem(title: "\(statusIndicator)\(service.displayName)", action: nil, keyEquivalent: "")

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
        let enabledServices = configuration.services.filter { $0.isEnabled }
        let runningCount = enabledServices.filter { service in
            serviceStatuses[service.id]?.isRunning ?? false
        }.count

        if enabledServices.isEmpty {
            return "Status: No services configured"
        }

        return "Status: \(runningCount) of \(enabledServices.count) services running"
    }

    private func updateMenuBarIcon() {
        guard let button = statusItem?.button else { return }

        button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "InfraProxy")
        button.image?.size = NSSize(width: 18, height: 18)

        let enabledServices = configuration.services.filter { $0.isEnabled }
        let runningCount = enabledServices.filter { service in
            serviceStatuses[service.id]?.isRunning ?? false
        }.count

        let color: NSColor
        if enabledServices.isEmpty {
            color = .systemGray
        } else if runningCount == enabledServices.count {
            color = .systemGreen
        } else if runningCount > 0 {
            color = .systemOrange
        } else {
            color = .systemRed
        }

        button.image = button.image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [color])
        )
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

    // MARK: - Service Actions

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

            // Refresh status after a short delay
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

            // Refresh status after a short delay
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

            // Refresh status after a short delay
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
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = message
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    @objc func quitApp() {
        stopStatusRefresh()
        NSApplication.shared.terminate(nil)
    }
}
