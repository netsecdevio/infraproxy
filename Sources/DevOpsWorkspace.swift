import Cocoa
import SwiftUI
import UserNotifications
import ServiceManagement

struct DevOpsView: View {
    @ObservedObject var model: DevOpsModel
    @State private var page = "Monitors"
    @State private var search = ""
    @State private var filter = "All"
    @State private var editor: DevOpsMonitor?
    @State private var issue: DevOpsIssue?
    @State private var pending: DevOpsConfiguration?
    @State private var encryptedImport: Data?
    @State private var restoredImport: DevOpsConfiguration?
    @State private var backupMode: String?
    @State private var issueBusy = false
    private var visible: [DevOpsMonitor] {
        model.monitors.filter { item in
            (search.isEmpty || (item.name + " " + item.group + " " + DevOpsProvider.title(item.type)).localizedCaseInsensitiveContains(search)) &&
            (filter == "All" || (filter == "Paused" ? !item.enabled : (filter == "Muted" ? item.muted : (item.enabled && (filter == "Unavailable" ? (model.results[item.id] == nil || model.stale(item.id) || model.results[item.id]?.health == .unknown) : (!model.stale(item.id) && model.results[item.id]?.health.rawValue == filter))))))
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) { Text("DevOps").font(.title2.bold()); Text(model.summary).foregroundStyle(.secondary) }
                Spacer()
                if !model.loaded { Button("Unlock", action: model.load) }
                Button("Refresh", action: model.refresh).disabled(!model.loaded || model.refreshing)
                Button("Add monitor") { editor = DevOpsMonitor(type: "githubAction", fields: [:]) }.disabled(!model.loaded)
            }.padding(24)
            Picker("DevOps workspace", selection: $page) { Text("Monitors").tag("Monitors"); Text("Settings & backups").tag("Settings") }.pickerStyle(.segmented).padding(.horizontal, 24)
            if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.top, 8) }
            if page == "Settings" {
                DevOpsPreferencesView(model: model, importAction: importFile, exportAction: { backupMode = "export" }, templateAction: exportTemplate)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            TextField("Find monitors or groups", text: $search)
                            Picker("Show", selection: $filter) { ForEach(["All", "Needs attention", "Running", "Healthy", "Unavailable", "Muted", "Paused"], id: \.self) { Text($0) } }.frame(width: 230)
                        }
                        if model.monitors.isEmpty {
                            SettingsSection("Connect your build and monitoring services") {
                                Text("Add a monitor, paste a provider link during setup, or import your Barklarm configuration. Test access before enabling monitoring.")
                                HStack { Button("Set up a provider") { editor = DevOpsMonitor(type: "githubAction", fields: [:]) }; Button("Import configuration…", action: importFile) }.disabled(!model.loaded)
                            }
                        } else if visible.isEmpty { Text("No monitors match these filters.").foregroundStyle(.secondary) }
                        ForEach(Array(Set(visible.map { $0.group.isEmpty ? "Ungrouped" : $0.group })).sorted(), id: \.self) { group in
                            SettingsSection(group) {
                                ForEach(visible.filter { ($0.group.isEmpty ? "Ungrouped" : $0.group) == group }) { monitor in
                                    monitorRow(monitor)
                                }
                            }
                        }
                    }.padding(24)
                }
            }
        }.onAppear(perform: model.load)
            .dropDestination(for: URL.self) { urls, _ in
                guard model.loaded, urls.count == 1, let url = urls.first, let monitor = try? DevOpsSetup.fromLink(url.absoluteString) else { return false }
                editor = monitor; return true
            }
            .sheet(item: $editor) { draft in DevOpsSetupView(initial: draft, existing: model.monitors.contains { $0.id == draft.id }) { monitor in
                try model.save(model.monitors.filter { $0.id != monitor.id } + [monitor])
            } }
            .sheet(item: $issue) { value in
                VStack(alignment: .leading, spacing: 18) {
                    Text("Create issue").font(.title2.bold())
                    Text("Send this monitor’s name, status, provider link and failure summary to \(value.endpoint.host ?? "")?")
                    Text(String(data: value.body, encoding: .utf8) ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Credentials are not included. This sends one POST request and may create an issue in your configured service.").font(.caption).foregroundStyle(.secondary)
                    HStack { Button("Cancel") { issue = nil }.disabled(issueBusy); Spacer(); Button("Send issue") { sendIssue(value) }.disabled(issueBusy) }
                }.padding(24).frame(width: 520)
            }
            .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) { importReview }
            .sheet(isPresented: Binding(get: { backupMode != nil }, set: { if !$0 { backupMode = nil; encryptedImport = nil } }), onDismiss: {
                pending = restoredImport; restoredImport = nil
            }) {
                DevOpsBackupView(exporting: backupMode == "export", configuration: model.configuration, encrypted: encryptedImport) { config in
                    restoredImport = config; backupMode = nil; encryptedImport = nil
                }
            }
    }
    @ViewBuilder private func monitorRow(_ monitor: DevOpsMonitor) -> some View {
        let result = model.results[monitor.id]
        let stale = model.stale(monitor.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(!monitor.enabled || stale ? Color.secondary : color(result?.health)).frame(width: 8, height: 8)
                Text(monitor.name).bold(); Spacer()
                Text(!monitor.enabled ? "Paused" : (stale && result != nil ? "Stale" : result?.health.rawValue ?? "Not checked")).foregroundStyle(.secondary)
                if let url = result?.link { Link("Open", destination: url) }
                Button("Edit") { editor = monitor }
                Menu {
                    Button(monitor.muted ? "Unmute alerts" : "Mute alerts") { modify(monitor) { $0.muted.toggle() } }
                    Button(monitor.enabled ? "Pause monitor" : "Resume monitor") { modify(monitor) { $0.enabled.toggle() } }
                    Button("Duplicate") { var copy = monitor; copy.id = UUID(); copy.fields["alias"] = monitor.name + " copy"; editor = copy }
                    Button("Remove") { save { try model.save(model.monitors.filter { $0.id != monitor.id }) } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
            HStack {
                Text(DevOpsProvider.title(monitor.type)); if monitor.muted { Label("Muted", systemImage: "bell.slash") }
                if let checked = result?.checked { Text("Checked \(checked.formatted(date: .omitted, time: .standard))") }
                Spacer()
                if let result, let prepared = try? DevOpsIssue.prepare(monitor: monitor, result: result, preferences: model.preferences) { Button("Create issue…") { issue = prepared }.disabled(!monitor.enabled) }
            }.font(.caption).foregroundStyle(.secondary)
            if let result, result.health == .unknown { Text(result.detail).font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 6)
    }
    private func color(_ health: DevOpsHealth?) -> Color { health == .healthy ? .green : (health == .failed ? .red : (health == .running ? .orange : .secondary)) }
    private func save(_ action: () throws -> Void) { do { try action(); model.message = "Saved in Keychain." } catch { model.message = "Could not save. Check credentials, endpoint and Keychain access. Edit an incomplete monitor before resuming it." } }
    private func modify(_ item: DevOpsMonitor, change: (inout DevOpsMonitor) -> Void) { var copy = item; change(&copy); save { try model.save(model.monitors.map { $0.id == copy.id ? copy : $0 }) } }
    private func sendIssue(_ value: DevOpsIssue) {
        issueBusy = true
        Task { @MainActor in
            do { _ = try await DevOpsHTTP().fetch(value.request, acceptedStatus: 200..<300); model.message = "Issue request accepted by the configured service." }
            catch { model.message = "Issue submission did not confirm success. Check the destination before retrying to avoid duplicates." }
            issueBusy = false; issue = nil
        }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a Barklarm JSON configuration, infravibe template, or encrypted backup."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 3_000_000 else { throw DevOpsError.invalidConfiguration }
            let data = try Data(contentsOf: url)
            if DevOpsBackup.encrypted(data) { encryptedImport = data; backupMode = "import" }
            else { pending = try DevOpsConfiguration.decode(data) }
        } catch { model.message = "Could not read this configuration. Nothing was changed." }
    }
    @ViewBuilder private var importReview: some View {
        if let config = pending {
            VStack(alignment: .leading, spacing: 16) {
                Text("Review configuration import").font(.title2.bold())
                Text("\(config.monitors.count) monitors · checks every \(config.preferences.refreshSeconds / 60) minute(s). Templates without credentials stay paused.")
                ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(config.monitors) { item in Text("\(item.name) · \(DevOpsProvider.title(item.type)) · \((try? DevOpsAdapter.request(item).url?.host) ?? "Configure credentials")") } } }.frame(maxHeight: 260)
                Text("Merge adds these monitors with new IDs and keeps current settings. Replace restores this configuration, including its polling and issue settings. TLS verification stays enabled.").font(.caption)
                if !config.preferences.issueEndpoint.isEmpty { Text("Issue endpoint: \(URL(string: config.preferences.issueEndpoint)?.host ?? "Invalid")").font(.caption) }
                HStack {
                    Button("Cancel") { pending = nil }; Spacer()
                    Button("Merge monitors") { importConfiguration(config, replace: false) }
                    Button("Replace configuration") { importConfiguration(config, replace: true) }
                }
            }.padding(24).frame(width: 600)
        }
    }
    private func importConfiguration(_ config: DevOpsConfiguration, replace: Bool) {
        do {
            var value = config
            if !replace { value.monitors = model.monitors + config.monitors.map { item in var copy = item; copy.id = UUID(); return copy }; value.preferences = model.preferences }
            try model.save(value); model.message = "Configuration imported into Keychain."; pending = nil
        } catch { model.message = "Import could not be saved. Check the monitor configuration and Keychain access." }
    }
    private func exportTemplate() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "infravibe-monitors-template.json"
        panel.message = "Exports account names and monitor configuration, without credentials or URL query parameters. Imported monitors will be paused."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let data = try JSONEncoder().encode(model.configuration.template()); try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path); model.message = "Credential-free template exported." }
        catch { model.message = "Could not export the template." }
    }
}

struct DevOpsSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DevOpsMonitor
    let existing: Bool
    let save: (DevOpsMonitor) throws -> Void
    @State private var step = 0
    @State private var link = ""
    @State private var feedback = ""
    @State private var testResult: DevOpsResult?
    @State private var busy = false
    @State private var choices: [DevOpsChoice] = []
    init(initial: DevOpsMonitor, existing: Bool, save: @escaping (DevOpsMonitor) throws -> Void) { _draft = State(initialValue: initial); self.existing = existing; self.save = save }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(existing ? "Edit monitor" : "Set up monitor").font(.title2.bold()); Spacer(); Text("\(step + 1) of 3").foregroundStyle(.secondary) }
            Text(["Choose a provider", "Configure and test access", "Review and save"][step]).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if step == 0 {
                        TextField("Paste a workflow, monitor, alert or CCTray link", text: $link)
                        Button("Use link") { do { let value = try DevOpsSetup.fromLink(link); draft.type = value.type; draft.fields = value.fields; feedback = "Provider details filled from link." } catch { feedback = "Unrecognized provider link. Choose a provider below." } }
                        Picker("Provider", selection: $draft.type) { ForEach(DevOpsProvider.types, id: \.self) { Text(DevOpsProvider.title($0)).tag($0) } }.disabled(existing)
                        Text(DevOpsSetup.help(draft.type)).foregroundStyle(.secondary)
                    } else if step == 1 {
                        Text(DevOpsSetup.help(draft.type)).font(.callout).foregroundStyle(.secondary)
                        ForEach(DevOpsProvider.fields(draft.type), id: \.self) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(DevOpsProvider.label(key)).font(.caption).foregroundStyle(.secondary)
                                if DevOpsProvider.secret(key) { SecureField(DevOpsProvider.label(key), text: field(key)) }
                                else { TextField(DevOpsProvider.label(key), text: field(key)) }
                            }
                        }
                        if DevOpsDiscovery.field(draft.type) != nil {
                            HStack {
                                Button("Discover available resources", action: discover)
                                if !choices.isEmpty { Menu("Choose a resource") { ForEach(choices) { choice in Button(choice.title) { if let key = DevOpsDiscovery.field(draft.type) { draft.fields[key] = choice.id; testResult = nil } } } } }
                            }
                            Text("Discovery reads the first page (up to 100 resources). You can enter another resource directly.").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Test connection", action: test)
                        if let result = testResult { Label(result.health == .unknown ? result.detail : "Connection verified · " + result.health.rawValue, systemImage: result.health == .unknown ? "exclamationmark.triangle" : "checkmark.circle") }
                    } else {
                        TextField("Display name", text: field("alias"))
                        TextField("Group, e.g. Production", text: $draft.group)
                        Toggle("Mute notifications for this monitor", isOn: $draft.muted)
                        TextField("Issue endpoint override (optional HTTPS URL)", text: field("issueEndpoint"))
                        Text("Issue actions send a reviewed request only when you choose Create issue. Leave empty to use the global endpoint.").font(.caption).foregroundStyle(.secondary)
                        LabeledContent("Provider", value: DevOpsProvider.title(draft.type))
                        LabeledContent("Destination", value: (try? DevOpsAdapter.request(draft).url?.host) ?? "Not configured")
                        Text(testResult == nil ? "Not tested. Save paused, or go back and test access before enabling checks." : (testResult?.health == .unknown ? "Access could not be verified. You can save this monitor paused and finish setup later." : "Credentials will be saved in this Mac’s Keychain."))
                    }
                }.disabled(busy)
            }.frame(minHeight: 280, maxHeight: 480)
            if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Cancel") { dismiss() }; Spacer()
                if step > 0 { Button("Back") { step -= 1 }.disabled(busy) }
                if step < 2 { Button("Continue") { step += 1; feedback = "" }.disabled(busy) }
                else {
                    Button("Save paused") { finish(enabled: false) }.disabled(busy)
                    Button("Save and monitor") { finish(enabled: true) }.disabled(busy || testResult == nil || testResult?.health == .unknown)
                }
            }
        }.padding(24).frame(width: 620)
            .onChange(of: draft.type) { old, new in
                if old != new {
                    if let parsed = try? DevOpsSetup.fromLink(link), parsed.type == new { draft.fields = parsed.fields }
                    else { draft.fields = DevOpsSetup.defaults(new); link = "" }
                    choices = []; testResult = nil
                }
            }
            .onChange(of: draft.fields) { old, new in
                if DevOpsProvider.fields(draft.type).contains(where: { old[$0] != new[$0] }) { testResult = nil }
            }
    }
    private func field(_ key: String) -> Binding<String> { Binding(get: { draft.fields[key] ?? "" }, set: { draft.fields[key] = $0 }) }
    private func test() {
        busy = true; feedback = "Checking provider…"; let value = draft
        Task { @MainActor in let result = await DevOpsModel.check(value); if value == draft { testResult = result }; busy = false; feedback = "" }
    }
    private func discover() {
        busy = true; feedback = "Loading resources…"; let value = draft
        Task { @MainActor in
            do {
                let data = try await DevOpsHTTP().fetch(DevOpsDiscovery.request(value))
                let items = try DevOpsDiscovery.choices(data, type: value.type)
                if value == draft { choices = items; feedback = items.isEmpty ? "No resources returned. Check access or enter the resource directly." : "Found \(items.count) resources. Choose one above." }
            } catch { feedback = "Discovery failed. Check server/account fields and read permissions, or enter the resource directly." }
            busy = false
        }
    }
    private func finish(enabled: Bool) {
        var value = draft; value.enabled = enabled
        value.fields = value.fields.filter { (DevOpsProvider.fields(value.type) + ["alias", "issueEndpoint"]).contains($0.key) }
        do { try save(value); dismiss() } catch { feedback = "Could not save. Check the issue URL, configuration and Keychain access." }
    }
}

struct DevOpsPreferencesView: View {
    @ObservedObject var model: DevOpsModel
    let importAction: () -> Void
    let exportAction: () -> Void
    let templateAction: () -> Void
    @State private var draft = DevOpsPreferences()
    @State private var message = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Monitoring") {
                    Toggle("Check monitors automatically", isOn: $draft.automaticRefresh)
                    Stepper("Check every \(draft.refreshSeconds / 60) minute(s)", value: $draft.refreshSeconds, in: 60...3600, step: 60)
                    Text("Manual refresh stays available when automatic checks are paused. Configured monitors resume with these preferences when infravibe opens.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("Alerts") {
                    Toggle("Notify when a monitor fails", isOn: $draft.notifications)
                    Toggle("Notify when it recovers", isOn: $draft.notifyRecovery).disabled(!draft.notifications)
                    Toggle("Also notify about running and unavailable states", isOn: $draft.notifyAllChanges).disabled(!draft.notifications)
                    Toggle("Play notification sound", isOn: $draft.sound).disabled(!draft.notifications)
                    Text("Mute individual monitors from their menu. Notifications require permission in macOS System Settings.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("Issue creation") {
                    TextField("Global issue endpoint (HTTPS)", text: $draft.issueEndpoint)
                    Text("A monitor can override this destination. Create issue shows the destination and payload before sending; credentials are never included.").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Text(message).font(.caption); Spacer(); Button("Save preferences", action: save).disabled(!model.loaded) }
                SettingsSection("Configuration & backups") {
                    HStack { Button("Import…", action: importAction); Button("Encrypted backup…", action: exportAction); Button("Export template…", action: templateAction) }.disabled(!model.loaded)
                    Text("Encrypted backups include credentials and preferences. Templates omit credentials and restore paused monitors. Import supports Barklarm JSON and infravibe backups.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("Application") {
                    DevOpsLoginItemView()
                    Text("Application updates are configured in Advanced. Certificate verification stays enabled for every provider.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(24)
        }.onAppear { draft = model.preferences }.onChange(of: model.preferences) { _, value in draft = value }
    }
    private func save() {
        do {
            try model.save(DevOpsConfiguration(monitors: model.monitors, preferences: draft)); message = "Preferences saved."
            if draft.notifications { UNUserNotificationCenter.current().requestAuthorization(options: draft.sound ? [.alert, .sound] : [.alert]) { _, _ in } }
        } catch { message = "Could not save. Use an HTTPS issue endpoint and check Keychain access." }
    }
}
struct DevOpsLoginItemView: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading) {
            Toggle("Open infravibe at login", isOn: Binding(get: { enabled }, set: { wanted in
                do { if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; enabled = SMAppService.mainApp.status == .enabled; message = SMAppService.mainApp.status == .requiresApproval ? "Enable infravibe in System Settings → General → Login Items." : "" }
                catch { message = "Could not change the login item. Use System Settings → General → Login Items." }
            }))
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
struct DevOpsBackupView: View {
    let exporting: Bool
    let configuration: DevOpsConfiguration
    let encrypted: Data?
    let complete: (DevOpsConfiguration?) -> Void
    @State private var password = ""
    @State private var confirm = ""
    @State private var message = ""
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exporting ? "Encrypted configuration backup" : "Unlock backup").font(.title2.bold())
            Text(exporting ? "Includes monitor credentials and settings. Choose a password of at least 12 characters and keep it separately; it cannot be recovered by infravibe." : "Enter the password used when this backup was created.")
            SecureField("Backup password", text: $password)
            if exporting { SecureField("Confirm password", text: $confirm) }
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { complete(nil) }.disabled(busy); Spacer()
                Button(exporting ? "Save backup…" : "Unlock") { run() }.disabled(busy || password.utf8.count < 12 || (exporting && password != confirm))
            }
        }.padding(24).frame(width: 480)
    }
    private func run() {
        busy = true
        let secret = password, config = configuration, input = encrypted, exporting = exporting
        Task { @MainActor in
            do {
                if exporting {
                    let data = try await Task.detached { try DevOpsBackup.seal(config, password: secret) }.value
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "infravibe-devops-backup.json"
                    if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path); password = ""; confirm = ""; complete(nil) }
                } else if let input {
                    let restored = try await Task.detached { try DevOpsBackup.open(input, password: secret) }.value
                    password = ""; complete(restored)
                }
            } catch { message = exporting ? "Could not save the backup." : "Incorrect password, damaged backup, or unsupported format. Nothing was imported." }
            busy = false
        }
    }
}
