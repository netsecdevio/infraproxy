import Cocoa
import Foundation
import UserNotifications

// MARK: - InfraProxyManager Actions Extension
extension InfraProxyManager {

    // MARK: - Configuration Management

    func loadConfiguration() {
        let defaults = UserDefaults.standard

        // Load services from JSON
        if let data = defaults.data(forKey: UserDefaults.servicesKey) {
            do {
                let services = try JSONDecoder().decode([LaunchctlService].self, from: data)
                configuration.services = services
                log(.info, "Loaded \(services.count) services from configuration")
            } catch {
                log(.error, "Failed to decode services: \(error.localizedDescription)")
                configuration.services = []
            }
        }

        configuration.showNotifications = defaults.bool(forKey: UserDefaults.showNotificationsKey)

        // Set default for showNotifications if not set
        if defaults.object(forKey: UserDefaults.showNotificationsKey) == nil {
            configuration.showNotifications = true
        }

        log(.info, "Configuration loaded: \(configuration.services.count) services")
    }

    internal func saveConfiguration() {
        let defaults = UserDefaults.standard

        // Save services as JSON
        do {
            let data = try JSONEncoder().encode(configuration.services)
            defaults.set(data, forKey: UserDefaults.servicesKey)
        } catch {
            log(.error, "Failed to encode services: \(error.localizedDescription)")
        }

        defaults.set(configuration.showNotifications, forKey: UserDefaults.showNotificationsKey)

        log(.info, "Configuration saved: \(configuration.services.count) services")
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

        settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow?.title = "InfraProxy Settings"
        settingsWindow?.center()
        settingsWindow?.isReleasedWhenClosed = false

        guard let contentView = settingsWindow?.contentView else { return }

        var yPosition: CGFloat = 460

        // Header
        let headerLabel = NSTextField(labelWithString: "Launchctl Services")
        headerLabel.frame = NSRect(x: 20, y: yPosition, width: 560, height: 20)
        headerLabel.font = NSFont.boldSystemFont(ofSize: 14)
        contentView.addSubview(headerLabel)

        yPosition -= 10

        // Description
        let descLabel = NSTextField(labelWithString: "Manage services that can be started via launchctl")
        descLabel.frame = NSRect(x: 20, y: yPosition, width: 560, height: 16)
        descLabel.font = NSFont.systemFont(ofSize: 11)
        descLabel.textColor = .secondaryLabelColor
        contentView.addSubview(descLabel)

        yPosition -= 30

        // Services table
        let scrollView = NSScrollView()
        scrollView.frame = NSRect(x: 20, y: 120, width: 560, height: yPosition - 120)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autoresizingMask = [.width, .height]

        let tableView = NSTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.delegate = self
        tableView.dataSource = self

        // Name column
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 120
        nameColumn.minWidth = 80
        tableView.addTableColumn(nameColumn)

        // Label column
        let labelColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("label"))
        labelColumn.title = "Launchctl Label"
        labelColumn.width = 200
        labelColumn.minWidth = 100
        tableView.addTableColumn(labelColumn)

        // Category column
        let categoryColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        categoryColumn.title = "Category"
        categoryColumn.width = 100
        categoryColumn.minWidth = 80
        tableView.addTableColumn(categoryColumn)

        // Port column
        let portColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("port"))
        portColumn.title = "Port"
        portColumn.width = 60
        portColumn.minWidth = 50
        tableView.addTableColumn(portColumn)

        // Enabled column
        let enabledColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("enabled"))
        enabledColumn.title = "Enabled"
        enabledColumn.width = 60
        enabledColumn.minWidth = 50
        tableView.addTableColumn(enabledColumn)

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)
        servicesTableView = tableView

        // Add/Edit/Remove buttons
        let addButton = NSButton(title: "+", target: self, action: #selector(addService))
        addButton.frame = NSRect(x: 20, y: 85, width: 30, height: 25)
        addButton.bezelStyle = .smallSquare
        contentView.addSubview(addButton)

        let removeButton = NSButton(title: "-", target: self, action: #selector(removeService))
        removeButton.frame = NSRect(x: 50, y: 85, width: 30, height: 25)
        removeButton.bezelStyle = .smallSquare
        contentView.addSubview(removeButton)

        let editButton = NSButton(title: "Edit", target: self, action: #selector(editService))
        editButton.frame = NSRect(x: 90, y: 85, width: 50, height: 25)
        editButton.bezelStyle = .smallSquare
        contentView.addSubview(editButton)

        // Separator
        let separatorLine = NSBox()
        separatorLine.frame = NSRect(x: 20, y: 70, width: 560, height: 1)
        separatorLine.boxType = .separator
        contentView.addSubview(separatorLine)

        // Show notifications checkbox
        let notificationsCheckbox = NSButton(checkboxWithTitle: "Show notifications for service events", target: nil, action: nil)
        notificationsCheckbox.frame = NSRect(x: 20, y: 40, width: 300, height: 20)
        notificationsCheckbox.state = configuration.showNotifications ? .on : .off
        notificationsCheckbox.identifier = NSUserInterfaceItemIdentifier("notificationsCheckbox")
        contentView.addSubview(notificationsCheckbox)

        // Buttons at bottom
        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveSettings))
        saveButton.frame = NSRect(x: 500, y: 10, width: 80, height: 30)
        saveButton.keyEquivalent = "\r"
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelSettings))
        cancelButton.frame = NSRect(x: 410, y: 10, width: 80, height: 30)
        cancelButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelButton)
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
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        serviceEditWindow?.title = isEditing ? "Edit Service" : "Add Service"

        guard let contentView = serviceEditWindow?.contentView else { return }

        var yPosition: CGFloat = 300

        // Name
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

        // Launchctl Label
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

        // Port
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

        // Category
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

        // Description
        let descLabel = NSTextField(labelWithString: "Description:")
        descLabel.frame = NSRect(x: 20, y: yPosition, width: 100, height: 20)
        contentView.addSubview(descLabel)

        let descField = NSTextField()
        descField.frame = NSRect(x: 130, y: yPosition - 40, width: 300, height: 60)
        descField.stringValue = editingService.description
        descField.identifier = NSUserInterfaceItemIdentifier("editDescField")
        descField.placeholderString = "Description of the service"
        descField.cell?.usesSingleLineMode = false
        descField.cell?.wraps = true
        contentView.addSubview(descField)

        yPosition -= 80

        // Enabled
        let enabledCheckbox = NSButton(checkboxWithTitle: "Enabled (show in menu)", target: nil, action: nil)
        enabledCheckbox.frame = NSRect(x: 130, y: yPosition, width: 200, height: 20)
        enabledCheckbox.state = editingService.isEnabled ? .on : .off
        enabledCheckbox.identifier = NSUserInterfaceItemIdentifier("editEnabledCheckbox")
        contentView.addSubview(enabledCheckbox)

        // Buttons
        let saveEditButton = NSButton(title: isEditing ? "Save" : "Add", target: nil, action: nil)
        saveEditButton.frame = NSRect(x: 350, y: 10, width: 80, height: 30)
        saveEditButton.keyEquivalent = "\r"
        contentView.addSubview(saveEditButton)

        let cancelEditButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelEditButton.frame = NSRect(x: 260, y: 10, width: 80, height: 30)
        cancelEditButton.keyEquivalent = "\u{1b}"
        contentView.addSubview(cancelEditButton)

        // Store service ID for editing
        let serviceId = editingService.id

        // Set up button actions with closures
        saveEditButton.target = self
        saveEditButton.action = #selector(saveServiceEdit(_:))
        saveEditButton.tag = isEditing ? 1 : 0

        cancelEditButton.target = self
        cancelEditButton.action = #selector(cancelServiceEdit)

        // Store the service ID in the window for later retrieval
        serviceEditWindow?.representedFilename = serviceId.uuidString

        parentWindow.beginSheet(serviceEditWindow!) { _ in }
    }

    @objc func saveServiceEdit(_ sender: NSButton) {
        guard let editWindow = serviceEditWindow,
              let contentView = editWindow.contentView else { return }

        let isEditing = sender.tag == 1

        // Get field values
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

        // Validate required fields
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
            alert.informativeText = "Please enter the launchctl label for the service."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Parse port
        let port: Int?
        let portString = portField.stringValue.trimmingCharacters(in: .whitespaces)
        if portString.isEmpty {
            port = nil
        } else if let portValue = Int(portString), portValue > 0 && portValue <= 65535 {
            port = portValue
        } else {
            let alert = NSAlert()
            alert.messageText = "Invalid Port"
            alert.informativeText = "Port must be a number between 1 and 65535, or leave empty."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        // Get category
        let categoryTitle = categoryPopup.selectedItem?.title ?? "General"
        let category = ServiceCategory.allCases.first { $0.displayName == categoryTitle } ?? .general

        // Create/update service
        if isEditing {
            // Find the service to update by ID stored in window
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
        // Save notifications setting
        if let notificationsCheckbox = settingsWindow?.contentView?.subviews.first(where: {
            ($0 as? NSButton)?.identifier?.rawValue == "notificationsCheckbox"
        }) as? NSButton {
            configuration.showNotifications = notificationsCheckbox.state == .on
        }

        // Save services
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
        case "port":
            textField.stringValue = service.port.map { String($0) } ?? "-"
        case "enabled":
            textField.stringValue = service.isEnabled ? "Yes" : "No"
        default:
            textField.stringValue = ""
        }

        return textField
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Could enable/disable edit/remove buttons based on selection
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
