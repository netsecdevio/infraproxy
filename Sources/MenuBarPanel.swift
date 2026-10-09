import Cocoa
import SwiftUI

enum InterfaceTheme: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
}
enum DashboardTab: String { case connections, browser, remote, cloud, updates, advanced, about }

private struct PanelAction: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 9).padding(.vertical, 8)
                .background(hovered ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).onHover { hovered = $0 }
    }
}
struct MenuBarPanel: View {
    @ObservedObject var manager: InfraProxyManager
    @ObservedObject var operations: OperationsModel
    @ObservedObject var remote: RemoteAccessModel
    @AppStorage("interfaceTheme") private var theme: InterfaceTheme = .system
    @Environment(\.colorScheme) private var colorScheme
    private var online: Int { operations.connections.filter(\.listening).count }
    private var sessions: Int { operations.connections.reduce(0) { $0 + $1.sessions.count } }
    private func open(_ tab: DashboardTab) { manager.closePanel(); manager.openDashboard(tab) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "network").font(.title2).foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("InfraProxy").font(.system(size: 15, weight: .semibold))
                        Text("Your infrastructure, connected").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(online > 0 ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(online > 0 ? "Active" : "Idle").font(.system(size: 10, weight: .medium))
                    }.padding(.horizontal, 8).padding(.vertical, 4).background(Color.primary.opacity(0.06), in: Capsule())
                }
                HStack(spacing: 16) {
                    Label("\(online) \(online == 1 ? "listener" : "listeners")", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(sessions) TCP sessions", systemImage: "arrow.left.arrow.right")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16).background(LinearGradient(colors: [Color.accentColor.opacity(colorScheme == .dark ? 0.09 : 0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("PROVIDERS")
                    VStack(spacing: 1) {
                        providerRow("Teleport", icon: "shield.lefthalf.filled", color: .purple, status: teleportStatus, active: operations.expiry.map { $0 > operations.now } ?? false) { open(.connections) }
                        providerRow("Tailscale", icon: "point.3.filled.connected.trianglepath.dotted", color: .blue, status: remote.tailMessage, active: remote.tailscale?.connected == true) { open(.remote) }
                        providerRow("Cloudflare", icon: "cloud.fill", color: .orange, status: remote.cloudflarePath == nil ? "Not installed" : "Ready to share", active: false) { open(.remote) }
                        providerRow("ngrok", icon: "arrow.down.forward.circle", color: .mint, status: remote.ngrokPath == nil ? "Not installed" : "Ready for inbound", active: false) { open(.remote) }
                        providerRow("Browser dashboard", icon: "terminal", color: .teal, status: "Inbound access to this Mac", active: false) { open(.browser) }
                        providerRow("Google Cloud", icon: "cloud", color: .cyan, status: "Accounts & projects", active: false) { open(.cloud) }
                    }
                    CompactTunnel(tunnel: remote.tailTunnel)
                    CompactTunnel(tunnel: remote.cloudTunnel)
                    CompactTunnel(tunnel: remote.ngrokTunnel)
                    if let hostname = remote.tailscale?.hostname, !hostname.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.shield").foregroundStyle(.secondary)
                            Text(hostname).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(hostname, forType: .string) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy Tailscale hostname")
                        }.font(.system(size: 10)).padding(.horizontal, 6)
                    }
                    Divider()
                    HStack {
                        section("LOCAL ACTIVITY")
                        Spacer()
                        Button("View all") { open(.connections) }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    }
                    if operations.connections.isEmpty {
                        Text("No configured listeners").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    } else {
                        ForEach(operations.connections) { connection in
                            HStack(spacing: 9) {
                                Circle().fill(connection.listening ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text("localhost:\(connection.port)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(connection.available ? "\(connection.sessions.count) sessions" : "Unavailable").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    HStack {
                        Button(manager.isRunning ? "Stop Teleport proxy" : "Start Teleport proxy") {
                            manager.closePanel()
                            if manager.isRunning { manager.stopProxy() } else { manager.startProxy() }
                        }.font(.system(size: 11))
                        Spacer()
                        Button("Log in") { manager.closePanel(); manager.loginToTeleport() }.font(.system(size: 11))
                    }
                }.padding(14)
            }.frame(height: 380)
            Divider()
            HStack(spacing: 2) {
                PanelAction(title: "Dashboard", icon: "square.grid.2x2") { open(.connections) }
                PanelAction(title: "Settings", icon: "gearshape") { manager.closePanel(); manager.showSettings() }
                Spacer(minLength: 0)
                Menu {
                    Button("Check for Updates…") { manager.closePanel(); manager.appUpdater.check() }
                    Button("About InfraProxy") { manager.closePanel(); manager.showAbout() }
                    Button("Show Logs…") { manager.closePanel(); manager.showLogs() }
                    Button("Advanced controls…") { manager.showAdvancedMenu() }
                    Divider()
                    Button("Quit InfraProxy") { manager.quitApp() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }.menuStyle(.borderlessButton).frame(width: 28).help("More actions")
            }.padding(.horizontal, 10).padding(.vertical, 8)
            HStack {
                Text("Appearance").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Picker("Appearance", selection: $theme) {
                    ForEach(InterfaceTheme.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).controlSize(.small).frame(width: 185)
            }.padding(.horizontal, 16).padding(.bottom, 12)
        }.frame(width: 400, height: 554).background(.regularMaterial).environment(\.colorScheme, theme.colorScheme ?? colorScheme)
    }
    private var teleportStatus: String {
        if operations.expiry == nil { return "Sign in to view expiry" }
        if operations.expiry! <= operations.now { return "Expired · Log in" }
        return TeleportExpiry.label(operations.expiry, now: operations.now) + " remaining"
    }
    private func section(_ text: String) -> some View { Text(text).font(.system(size: 9, weight: .semibold)).tracking(1).foregroundStyle(.secondary) }
    private func providerRow(_ title: String, icon: String, color: Color, status: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color).frame(width: 26, height: 28)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(status).font(.system(size: 10)).foregroundStyle(active ? Color.green : Color.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
private struct CompactTunnel: View {
    @ObservedObject var tunnel: SharedTunnel
    var body: some View {
        if tunnel.running {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(tunnel.provider?.rawValue ?? "Tunnel") · \(tunnel.message)").font(.system(size: 10, weight: .medium))
                if let url = tunnel.url, tunnel.ready { Link(url.absoluteString, destination: url).font(.system(size: 10)).lineLimit(1) }
                Button("Stop sharing", action: tunnel.stop).font(.system(size: 10))
            }.padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
