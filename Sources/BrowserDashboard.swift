import Cocoa
import SwiftUI
import UserNotifications

final class BrowserDashboard: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var message = "Stopped"
    @Published private(set) var sessions: [String] = []
    @Published private(set) var activePort = 4021
    @Published var portText = String(UserDefaults.standard.integer(forKey: "browserPort") == 0 ? 4021 : UserDefaults.standard.integer(forKey: "browserPort"))
    private var key = BrowserSecurity.token()
    private var engine: BrowserEngine?
    private var timer: Timer?
    private var restartPending = false
    weak var manager: InfraProxyManager?
    var localURL: URL? { running ? URL(string: "http://127.0.0.1:\(activePort)") : nil }
    func start() {
        guard !running, !starting, let port = RemoteCommands.port(portText, blocked: []) else { message = "Enter a port between 1 and 65535."; return }
        guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { message = "Application resources unavailable"; return }
        key = BrowserSecurity.token(); starting = true
        manager?.log(.debug, "Starting loopback browser server on port \(port)")
        let engine = BrowserEngine(assets: resources.appendingPathComponent("Web"), helper: executable.deletingLastPathComponent().appendingPathComponent("TerminalHost"), historyDirectory: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/InfraProxy/TerminalHistory"), agents: manager?.agentAccess ?? AgentAccess(), browserKeys: manager?.browserKeys ?? BrowserKeys())
        self.engine = engine
        engine.onSessionEvent = { event, code in
            let defaults = UserDefaults.standard
            guard defaults.bool(forKey: "sessionNotifications"), defaults.bool(forKey: "notifySession" + event) else { return }
            let content = UNMutableNotificationContent()
            content.title = event == "Start" ? "Session started" : "Session ended"
            content.body = code.map { "Terminal exited with code \($0)." } ?? "A terminal session started on this Mac."
            if defaults.bool(forKey: "sessionNotificationSound") { content.sound = .default }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        engine.onState = { [weak self, weak engine] running, port, message, sessions in
            guard let self, self.engine === engine else { return }
            self.running = running; self.starting = false; self.activePort = port; self.message = message; self.sessions = sessions
            if !running && self.restartPending {
                self.restartPending = false
                DispatchQueue.main.async { [weak self] in self?.start() }
            }
        }
        engine.start(port: port, key: key)
        UserDefaults.standard.set(port, forKey: "browserPort")
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshSnapshot() }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refreshSnapshot()
    }
    func stop() {
        manager?.log(.debug, "Stopping browser server and owned inbound tunnels")
        manager?.remoteAccess.stopDashboardTunnels(port: activePort)
        engine?.stop(); timer?.invalidate(); timer = nil
    }
    func restart() {
        restartPending = true
        stop()
    }
    func rotateKey() { key = BrowserSecurity.token(); engine?.rotate(key: key) }
    func copyKey() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string) }
    func openBrowser() {
        guard let url = localURL else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.fragment = "key=" + key
        NSWorkspace.shared.open(components.url!)
    }
    func endSession(_ id: String) { engine?.endTerminal(id) }
    private func refreshSnapshot() {
        guard let manager else { return }
        manager.browserKeys.refreshAuthorization()
        let operations = manager.operations
        let snapshot: [String: Any] = [
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "teleport": TeleportExpiry.label(operations.expiry, now: Date()),
            "listeners": operations.connections.map { ["name": $0.name, "port": $0.port, "listening": $0.listening, "sessions": $0.sessions.count] as [String: Any] },
            "sharing": manager.remoteAccess.readyURLs.map(\.absoluteString)
        ]
        engine?.update(snapshot: snapshot, remoteURLs: manager.remoteAccess.readyURLs)
    }
}

struct BrowserDashboardView: View {
    @ObservedObject var model: BrowserDashboard
    @ObservedObject var remote: RemoteAccessModel
    @State private var workspaceMessage = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Server configuration") {
                    LabeledContent("Status") { Label(model.message, systemImage: model.running ? "checkmark.circle.fill" : "circle").foregroundStyle(model.running ? .green : .secondary) }
                    LabeledContent("Access mode", value: "Localhost · authenticated browser access")
                    Divider()
                    HStack { Text("Port"); Spacer(); TextField("4021", text: $model.portText).frame(width: 85).disabled(model.running || model.starting) }
                    LabeledContent("Bind address", value: "127.0.0.1")
                    if let url = model.localURL { LabeledContent("Base URL") { Text(url.absoluteString).font(.system(.body, design: .monospaced)).textSelection(.enabled) } }
                    Divider()
                    HStack {
                        Text("Browser server"); Spacer()
                        if model.running {
                            Button("Open Browser", action: model.openBrowser)
                            Button("Restart", action: model.restart)
                            Button("Stop", action: model.stop)
                        } else { Button(model.starting ? "Starting…" : "Start", action: model.start).disabled(model.starting) }
                    }
                }
                Text("Host an authenticated dashboard and interactive shell on this Mac. Use the Inbound tab to reach it through Tailscale, ngrok, or Cloudflare.").font(.caption).foregroundStyle(.secondary)
                SettingsSection("Terminal workspaces") {
                    Text("Sessions can read and write only their selected approved workspace and a private temporary home. Network access and host credentials are blocked. Existing host tmux sessions cannot be attached.").font(.caption).foregroundStyle(.secondary)
                    Button("Approve repository folder…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                        panel.message = "Allow sessions to read and modify this repository and everything inside it."
                        if panel.runModal() == .OK, let url = panel.url {
                            workspaceMessage = SessionWorkspaces.approve(url) ? "Approved: " + url.path : "Choose a project folder inside your home, outside hidden folders and Library."
                        }
                    }
                    Text(workspaceMessage).font(.caption)
                }
                SettingsSection("Inbound access") {
                    TunnelControls(title: "Tailscale", tunnel: remote.tailTunnel)
                    Divider(); TunnelControls(title: "ngrok", tunnel: remote.ngrokTunnel)
                    Divider(); TunnelControls(title: "Cloudflare", tunnel: remote.cloudTunnel)
                }
                SettingsSection("Active terminal sessions · \(model.sessions.count)") {
                    if model.sessions.isEmpty { Text("No active browser terminals").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 12) }
                    ForEach(model.sessions, id: \.self) { id in
                        HStack { Label(String(id.prefix(8)), systemImage: "terminal"); Spacer(); Button("End session") { model.endSession(id) } }
                    }
                }
                Text("Closing a browser detaches its view; the shell keeps running. Use End session to stop it. Exited sessions retain bounded output previews. Stopping the server ends running terminals; detached jobs may continue.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
    }
}
