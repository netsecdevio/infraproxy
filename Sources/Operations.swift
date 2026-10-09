import Cocoa
import SwiftUI

struct VMInstance: Decodable, Identifiable {
    let name: String
    let zone: String
    let status: String
    var id: String { zone + "/" + name }
    var shortZone: String { zone.components(separatedBy: "/").last ?? zone }
}
struct ConnectionSnapshot: Identifiable {
    let name: String
    let port: String
    let listening: Bool
    let sessions: [String]
    let available: Bool
    var id: String { port }
}
enum TeleportExpiry {
    static func parse(_ output: String, proxy: String) -> Date? {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var profiles = root["profiles"] as? [[String: Any]] ?? []
        if let active = root["active"] as? [String: Any] { profiles.insert(active, at: 0) }
        func host(_ value: String) -> String {
            (URLComponents(string: value.contains("://") ? value : "https://" + value)?.host ?? value).lowercased()
        }
        guard let profile = profiles.first(where: { host($0["profile_url"] as? String ?? "") == host(proxy) }),
              let value = profile["valid_until"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func label(_ expiry: Date?, now: Date = Date()) -> String {
        guard let expiry else { return "Expiry unavailable" }
        let seconds = Int(ceil(expiry.timeIntervalSince(now)))
        guard seconds > 0 else { return "Expired — log in" }
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}

final class OperationsModel: ObservableObject {
    weak var manager: InfraProxyManager?
    @Published var tab: DashboardTab = .connections
    @Published var expiry: Date?
    @Published var now = Date()
    @Published var connections: [ConnectionSnapshot] = []
    @Published var statsMessage = "Checking connections…"
    let cloud = GoogleCloudModel()
    private var timer: Timer?
    private var refreshing = false
    private var ticks = 0
    deinit { timer?.invalidate() }
    func start() {
        refreshStats()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.now = Date()
            self.manager?.updateExpiryTitle(TeleportExpiry.label(self.expiry, now: self.now))
            self.ticks += 1
            if self.ticks % 5 == 0 { self.refreshStats() }
            if self.ticks % 30 == 0, self.manager?.dashboardWindow?.isVisible == true, !self.cloud.project.isEmpty { self.cloud.refreshResources() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func refreshStats() {
        guard !refreshing, let manager else { return }
        refreshing = true
        let config = manager.configuration
        var endpoints = [("Teleport SOCKS", config.teleport.localPort)]
        if config.httpProxy.enabled { endpoints.append(("HTTP proxy", config.httpProxy.port)) }
        endpoints += config.services.filter { $0.isEnabled && $0.port != nil }.map { ($0.name, String($0.port!)) }
        // Multiple configured services may describe the same listener. Count that port once.
        let uniqueEndpoints = Dictionary(grouping: endpoints, by: { $0.1 }).map { port, entries in
            (entries.map { $0.0 }.joined(separator: " / "), port)
        }.sorted { $0.1 < $1.1 }
        DispatchQueue.global(qos: .utility).async {
            let status = OperationsCommand.run(config.teleport.tshPath, ["status", "--format=json", "--add-keys-to-agent=no"])
            let expiry = TeleportExpiry.parse(status.output, proxy: config.teleport.teleportProxy)
            let snapshots = uniqueEndpoints.map { name, port -> ConnectionSnapshot in
                let result = OperationsCommand.run("/usr/sbin/lsof", ["-nP", "-a", "-iTCP:" + port, "-FpnT"])
                let lines = result.output.components(separatedBy: "\n")
                var endpoint = ""
                var sessions: [String] = []
                var listening = false
                for line in lines {
                    if line.hasPrefix("n") { endpoint = String(line.dropFirst()) }
                    if line == "TST=LISTEN" { listening = true }
                    if line == "TST=ESTABLISHED", endpoint.components(separatedBy: "->").first?.hasSuffix(":" + port) == true { sessions.append(endpoint) }
                }
                return ConnectionSnapshot(name: name, port: port, listening: listening, sessions: sessions, available: result.code == 0 || (result.code == 1 && result.output.isEmpty && result.diagnostic.isEmpty))
            }
            DispatchQueue.main.async {
                self.expiry = expiry
                self.connections = snapshots
                self.statsMessage = expiry == nil ? "Teleport expiry unavailable. Check login, configured proxy, and tsh path." : "Credential expiry; existing connections may follow cluster policy."
                self.refreshing = false
            }
        }
    }

}

struct OperationsView: View {
    @ObservedObject var model: OperationsModel
    let updater: AppUpdater
    @ObservedObject var manager: InfraProxyManager
    @AppStorage("interfaceTheme") private var theme: InterfaceTheme = .system
    var body: some View {
        TabView(selection: $model.tab) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Teleport credential expires in").font(.headline)
                        Text(TeleportExpiry.label(model.expiry, now: model.now)).font(.system(size: 34, weight: .medium, design: .monospaced)).foregroundStyle(model.expiry.map { $0 <= model.now.addingTimeInterval(300) } == true ? .orange : .primary)
                    }
                    Spacer()
                    Button("Log in") { model.manager?.loginToTeleport() }
                }
                Text(model.statsMessage).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 32) {
                    Text("\(model.connections.filter(\.listening).count) live listeners").font(.title2)
                    Text("\(model.connections.reduce(0) { $0 + $1.sessions.count }) TCP sessions").font(.title2)
                }
                List(model.connections) { connection in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: connection.listening ? "circle.fill" : "circle").foregroundStyle(connection.listening ? .green : .secondary)
                            Text(connection.name).bold()
                            Spacer()
                            Text(":\(connection.port) · \(connection.available ? (connection.listening ? "Listening" : "Stopped") : "Unavailable") · \(connection.sessions.count) sessions")
                        }
                        ForEach(Array(connection.sessions.enumerated()), id: \.offset) { _, session in Text(session).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.padding(.vertical, 6)
                }
                Text("Local accepted TCP sockets, refreshed every 5 seconds. HTTP-to-SOCKS forwarding appears on both listeners. These are not cluster-wide Teleport SSH sessions.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("Outbound", systemImage: "network") }.tag(DashboardTab.connections)
            BrowserDashboardView(model: manager.browserDashboard, remote: manager.remoteAccess).tabItem { Label("Dashboard", systemImage: "server.rack") }.tag(DashboardTab.browser)
            RemoteAccessView(model: manager.remoteAccess, manager: manager, browser: manager.browserDashboard).tabItem { Label("Inbound", systemImage: "point.3.connected.trianglepath.dotted") }.tag(DashboardTab.remote)
            GoogleCloudView(model: model.cloud).tabItem { Label("Google Cloud", systemImage: "cloud") }.tag(DashboardTab.cloud)
            AdvancedSettingsView(manager: manager, updater: updater).tabItem { Label("Advanced", systemImage: "gearshape.2") }.tag(DashboardTab.advanced)
            AgentAccessView(model: manager.agentAccess, browser: manager.browserDashboard).tabItem { Label("Agents", systemImage: "person.badge.key") }.tag(DashboardTab.agents)
            SessionNotificationSettings(browser: manager.browserDashboard).tabItem { Label("Notifications", systemImage: "bell") }.tag(DashboardTab.notifications)
            AboutSettingsView().tabItem { Label("About", systemImage: "info.circle") }.tag(DashboardTab.about)
        }.frame(minWidth: 1020, minHeight: 560).preferredColorScheme(theme.colorScheme)
    }
}
extension InfraProxyManager {
    @objc func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "infravibe — Operations"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OperationsView(model: operations, updater: appUpdater, manager: self))
            window.center()
            dashboardWindow = window
        }
        operations.refreshStats()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
