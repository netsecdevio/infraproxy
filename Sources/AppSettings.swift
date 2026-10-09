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
                        Button("Test") { terminalMessage = terminal.launch(command: "printf '\\nInfraProxy terminal ready.\\n'") ? "Opened \(terminal.title)." : "Could not open \(terminal.title). Check its installation and macOS Automation permission." }
                        Picker("Preferred terminal", selection: $terminal) { ForEach(PreferredTerminal.allCases) { item in Text(item.title + (item.installed ? "" : " · Not installed")).tag(item) } }.labelsHidden().frame(width: 180)
                    }
                    Text("Used for Google Cloud IAP SSH connections. Browser terminals use your Mac user’s login shell.").font(.caption).foregroundStyle(.secondary)
                    if !terminalMessage.isEmpty { Text(terminalMessage).font(.caption).foregroundStyle(.secondary) }
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
                    Text("Add operational diagnostics to the app log. Browser terminal content and access keys are never recorded.").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    HStack { Text("Application logs"); Spacer(); Button("Show Logs", action: manager.showLogs) }
                    HStack { Text("Outbound proxies and launch services"); Spacer(); Button("Configure…", action: manager.showProxySettings) }
                }
                SettingsSection("Browser session lifecycle") {
                    Text("Browser sessions expire after 8 hours. Terminals end when their browser connection closes. Stopping the server, quitting InfraProxy, or rotating its key ends all browser terminals.").font(.callout).foregroundStyle(.secondary)
                    Text("Inbound sharing is off until you start it. It is never restored automatically on launch.").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28)
        }
    }
}
struct AboutSettingsView: View {
    private let repository = "https://github.com/netsecdevio/infraproxy"
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(nsImage: NSApp.applicationIconImage).resizable().scaledToFit().frame(width: 110, height: 110).padding(.top, 20)
                Text("InfraProxy").font(.system(size: 29, weight: .bold))
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
                Text("MIT Licensed · InfraProxy contributors").font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
            }.frame(maxWidth: .infinity).padding(24)
        }
    }
}
