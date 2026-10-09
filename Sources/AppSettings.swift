import UserNotifications
import Cocoa
import SwiftUI

private struct SettingsLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack { configuration.label; Spacer(minLength: 20); configuration.content }
    }
}
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).padding(.horizontal, 8)
            VStack(alignment: .leading, spacing: 14) { content }.labeledContentStyle(SettingsLabelStyle()).padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
enum PreferredTerminal: String, CaseIterable, Identifiable {
    case terminal = "com.apple.Terminal", iterm = "com.googlecode.iterm2"
    var id: String { rawValue }
    var title: String { self == .terminal ? "Terminal" : "iTerm2" }
    var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) != nil }
    static var selected: PreferredTerminal { PreferredTerminal(rawValue: UserDefaults.standard.string(forKey: "preferredTerminal") ?? "") ?? .terminal }
    func script(command: String) -> String {
        let quoted = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch self {
        case .terminal: return "tell application id \"com.apple.Terminal\"\nactivate\ndo script \"\(quoted)\"\nend tell"
        case .iterm: return "tell application id \"com.googlecode.iterm2\"\nactivate\nset newWindow to (create window with default profile)\ntell current session of newWindow to write text \"\(quoted)\"\nend tell"
        }
    }
    func launch(command: String) -> Bool {
        guard installed else { return false }
        var error: NSDictionary?
        guard let script = NSAppleScript(source: script(command: command)) else { return false }
        script.executeAndReturnError(&error)
        return error == nil
    }
}
struct AdvancedSettingsView: View {
    @ObservedObject var manager: InfraProxyManager
    @ObservedObject var updater: AppUpdater
    @AppStorage("preferredTerminal") private var terminal: PreferredTerminal = .terminal
    @AppStorage("debugMode") private var debugMode = false
    @State private var terminalMessage = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Apps") {
                    HStack {
                        Text("Preferred terminal"); Spacer()
                        Button("Test") { terminalMessage = terminal.launch(command: "printf '\\ninfravibe terminal ready.\\n'") ? "Opened \(terminal.title)." : "Could not open \(terminal.title). Check its installation and macOS Automation permission." }
                        Picker("Preferred terminal", selection: $terminal) { ForEach(PreferredTerminal.allCases) { item in Text(item.title + (item.installed ? "" : " · Not installed")).tag(item) } }.labelsHidden().frame(width: 180)
                    }
                    Text("Used for Google Cloud IAP SSH connections. Browser terminals use your Mac user’s login shell.").font(.caption).foregroundStyle(.secondary)
                    if !terminalMessage.isEmpty { Text(terminalMessage).font(.caption).foregroundStyle(.secondary) }
                }
                SettingsSection("macOS permissions") {
                    LabeledContent("Accessibility", value: "Not required")
                    Text("infravibe does not control other apps through Accessibility.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Automation", value: "Requested when opening a native terminal")
                    Text("Google Cloud SSH and the terminal Test button ask macOS to control Terminal or iTerm2. Approve only the terminal you use.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Notifications", value: "Manage in the Notifications tab")
                    LabeledContent("Screen Recording", value: "Not required")
                    Text("Session previews render terminal output; they do not capture your screen.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Local Network", value: "For servers on your local network")
                    Text("macOS may request access when you connect to a private monitoring server or local infrastructure.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("Files and Folders", value: "As needed for protected folders")
                    Text("Approve session workspaces in Dashboard. macOS may separately ask for access to protected folders. Full Disk Access is not required. Workspace approval does not grant macOS privacy permissions.").font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systempreferences") { NSWorkspace.shared.open(url) }
                    }
                }
                SettingsSection("Updates") {
                    LabeledContent("Update channel", value: "Stable releases")
                    Text("Receive signed, notarized production releases for Apple Silicon and Intel.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text("Automatically check for updates"); Spacer(); Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: updater.setAutomaticChecks)).labelsHidden().toggleStyle(.switch) }
                    HStack { VStack(alignment: .leading) { Text("Check for updates"); Text("Installation is always your choice.").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Check Now", action: updater.check).disabled(!updater.canCheck) }
                }
                SettingsSection("Advanced") {
                    HStack { Text("Debug mode"); Spacer(); Toggle("Debug mode", isOn: $debugMode).labelsHidden().toggleStyle(.switch) }
                    Text("Add operational diagnostics to the app log. Access keys are never logged. Bounded terminal output is retained separately for session previews.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text("Application logs"); Spacer(); Button("Show Logs", action: manager.showLogs) }
                    HStack { Text("Outbound proxies and launch services"); Spacer(); Button("Configure…", action: manager.showProxySettings) }
                }
                SettingsSection("Browser session lifecycle") {
                    Text("Browser logins expire after 8 hours. Closing the browser detaches from running sessions. Shells have an 8-hour maximum lifetime. Stopping the server or quitting ends running terminals; rotating the browser key ends human terminals.").font(.callout).foregroundStyle(.secondary)
                    Text("Inbound sharing is off until you start it. It is never restored automatically on launch.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
struct AboutSettingsView: View {
    private let repository = "https://github.com/netsecdevio/infravibe"
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 110, height: 110).padding(.top, 20)
                Text("infravibe").font(.system(size: 29, weight: .bold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))").font(.caption).foregroundStyle(.secondary)
                Text("Your infrastructure, connected.").font(.headline).foregroundStyle(.secondary)
                Text("Manage outbound infrastructure access and reach this Mac’s dashboard and terminals from your browser.").multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 450)
                VStack(alignment: .leading, spacing: 14) {
                    Link(destination: URL(string: repository)!) { Label("View on GitHub", systemImage: "link") }
                    Link(destination: URL(string: repository + "/issues")!) { Label("Report an Issue", systemImage: "bubble.left.and.bubble.right") }
                    Link(destination: URL(string: repository + "/releases")!) { Label("Release notes", systemImage: "arrow.down.circle") }
                    Link(destination: URL(string: repository + "/graphs/contributors")!) { Label("Contributors", systemImage: "person.2") }
                }.padding(.vertical, 12)
                Text("Universal 2 · Apple Silicon + Intel\nmacOS 15.5 and later").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Divider().frame(maxWidth: 300).padding(.vertical, 8)
                Text("With thanks").font(.headline)
                Link("VibeTunnel · design and workflow inspiration", destination: URL(string: "https://github.com/amantus-ai/vibetunnel")!)
                Text("Sparkle · signed updates\nxterm.js · browser terminal rendering").font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Open source notices") {
                    if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
                }.buttonStyle(.link)
                Text("GPL-3.0 · infravibe contributors").font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
            }.frame(maxWidth: .infinity).padding(24)
        }
    }
}

struct AgentAccessView: View {
    @ObservedObject var model: AgentAccess
    @ObservedObject var browser: BrowserDashboard
    @State private var name = ""
    @State private var hours = 24.0
    @State private var message = ""
    @State private var pending: AgentGrant?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Connect your agent") {
                    Text("Give each agent its own identity. Start with device discovery; terminal control requires your separate approval on this Mac.")
                    LabeledContent("MCP endpoint", value: browser.localURL.map { $0.absoluteString + "/mcp" } ?? "Start the browser server in Dashboard")
                    Text("For another device, use your Tailscale HTTPS URL with /mcp. Configure its Authorization header as Bearer followed by the token. Never put tokens in URLs or prompts.").font(.caption).foregroundStyle(.secondary)
                    TextField("Agent name, e.g. My coding assistant", text: $name)
                    Picker("Credential lifetime", selection: $hours) { Text("1 hour").tag(1.0); Text("24 hours").tag(24.0); Text("7 days").tag(168.0) }
                    Button("Create read-only token and copy") {
                        if let token = model.create(name: name, hours: hours) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string); name = ""; message = "Token copied once. Save it in your agent client's secret configuration." }
                        else { message = "Enter a name or remove an old grant (maximum 32)." }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                SettingsSection("Agent permissions") {
                    if model.all.isEmpty { Text("No agents authorized").foregroundStyle(.secondary) }
                    ForEach(model.all) { grant in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(grant.name).bold(); Spacer(); Button("Revoke") { model.revoke(grant.id) } }
                            Text(grant.expires <= Date() ? "Expired" : grant.canControl ? "Terminal control until \(grant.terminalUntil!.formatted())" : "Read-only device discovery").font(.caption)
                            Text("Credential expires \(grant.expires.formatted())").font(.caption).foregroundStyle(.secondary)
                            if grant.requestedControl { Label("Agent requested terminal control", systemImage: "hand.raised").foregroundStyle(.orange) }
                            Button("Approve terminal control for 1 hour…") { pending = grant }.disabled(grant.expires <= Date())
                        }.padding(.vertical, 4)
                    }
                }
                SettingsSection("Recent agent activity") {
                    Text("Records identity, tool, outcome, and time. Commands, terminal content, and credentials are omitted.").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.activity.prefix(30)) { event in
                        VStack(alignment: .leading) { Text("\(event.agent) · \(event.action) · \(event.outcome)"); Text(event.date.formatted()).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.padding(28)
        }
        .alert("Grant terminal control?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Approve for 1 hour", role: .destructive) { if let pending { model.approveControl(pending.id) }; pending = nil }
        } message: { Text("This agent can run commands inside its approved workspace sandbox. Network access and inherited host credentials are blocked. Revoking access stops its infravibe terminal sessions. Child processes remain subject to the same sandbox.") }
    }
}

struct BrowserKeySettings: View {
    @ObservedObject var model: BrowserKeys
    @State private var message = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SSH authorized keys").font(.headline)
            Text("Trust is read from ~/.ssh/authorized_keys on this Mac. Only option-free Ed25519 entries are currently supported; entries with restrictions are rejected rather than weakened. Manage this file through your usual SSH administration workflow.").font(.caption).foregroundStyle(.secondary)
            Button("Open SSH folder") { NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")) }
            ForEach(model.all) { key in
                HStack { VStack(alignment: .leading) { Text(key.label); Text(key.id).font(.caption2).textSelection(.enabled) }; Spacer() }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// Template glyph stays readable in both light and dark macOS menu bars.
enum BrandMark {
    static var image: NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 3.5; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 2, y: 6)); path.line(to: NSPoint(x: 4, y: 2))
            path.move(to: NSPoint(x: 7, y: 9)); path.line(to: NSPoint(x: 10, y: 2))
            path.move(to: NSPoint(x: 13, y: 11)); path.line(to: NSPoint(x: 16, y: 2)); path.line(to: NSPoint(x: 20, y: 16))
            path.stroke(); return true
        }
        image.isTemplate = true; image.accessibilityDescription = "infravibe"; return image
    }
}


struct SessionNotificationSettings: View {
    @ObservedObject var browser: BrowserDashboard
    @AppStorage("sessionNotifications") private var enabled = false
    @AppStorage("notifySessionStart") private var starts = false
    @AppStorage("notifySessionEnd") private var ends = false
    @AppStorage("sessionNotificationSound") private var sound = false
    @State private var authorization = "Checking…"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Session notifications") {
                    Toggle("Show session notifications", isOn: $enabled)
                    LabeledContent("macOS permission", value: authorization)
                    LabeledContent("Session events", value: browser.running ? "Connected" : "Server stopped")
                    Text("Notifications appear on this Mac. Session output, commands, and working directories are excluded.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("Notification types") {
                    Toggle("Session starts", isOn: $starts)
                    Toggle("Session ends · includes exit code", isOn: $ends)
                    Text("Per-command failures, completion timing, and terminal bell alerts require shell event integration and are not available yet.").font(.caption).foregroundStyle(.secondary)
                }.disabled(!enabled)
                SettingsSection("Notification behavior") {
                    Toggle("Play sound", isOn: $sound).disabled(!enabled)
                    Text("Banner style and Notification Center visibility are controlled in macOS System Settings → Notifications → infravibe.").font(.caption).foregroundStyle(.secondary)
                    Button("Refresh permission status", action: refresh)
                }
            }.padding(28)
        }.onAppear(perform: refresh).onChange(of: enabled) { _, value in
            if value {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in refresh() }
            }
        }
    }
    private func refresh() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized: text = "Allowed"
            case .denied: text = "Blocked in System Settings"
            case .notDetermined: text = "Not requested"
            case .provisional: text = "Quiet delivery"
            @unknown default: text = "Unknown"
            }
            DispatchQueue.main.async { authorization = text }
        }
    }
}
