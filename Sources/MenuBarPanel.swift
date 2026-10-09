import Cocoa
import SwiftUI

enum InterfaceTheme: String, CaseIterable, Identifiable {
    case system = "System", light = "Light", dark = "Dark"
    var id: String { rawValue }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .dark ? .dark : .light) }
}
enum DashboardTab: String { case devops, connections, browser, remote, cloud, updates, advanced, agents, notifications, about }

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
                    Image(nsImage: BrandMark.image).foregroundStyle(Color.orange)
                        .frame(width: 32, height: 32).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("infravibe").font(.system(size: 15, weight: .semibold))
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
            VStack(alignment: .leading, spacing: 12) {
                Button { open(.connections) } label: {
                    HStack {
                        Label("Infrastructure", systemImage: "server.rack")
                        Spacer()
                        Text("\(online) online").foregroundStyle(.secondary)
                    }.font(.system(size: 12, weight: .medium))
                }.buttonStyle(.plain)
                HStack {
                    Text("Teleport").font(.system(size: 11))
                    Spacer()
                    Text(teleportStatus).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Divider()
                RemoteOverview(browser: manager.browserDashboard, remote: remote) { open(.browser) }
                Divider()
                DevOpsMenuSummary(model: operations.devops) { open(.devops) }
                Text("Barklarm · Builds & monitoring alerts")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            HStack(spacing: 2) {
                PanelAction(title: "Dashboard", icon: "square.grid.2x2") { open(.connections) }
                PanelAction(title: "Settings", icon: "gearshape") { manager.closePanel(); manager.showSettings() }
                Spacer(minLength: 0)
                Menu {
                    Button("Check for Updates…") { manager.closePanel(); manager.appUpdater.check() }
                    Button("About infravibe") { manager.closePanel(); manager.showAbout() }
                    Button("Show Logs…") { manager.closePanel(); manager.showLogs() }
                    Button("Advanced controls…") { manager.showAdvancedMenu() }
                    Divider()
                    Button("Quit infravibe") { manager.quitApp() }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }.menuStyle(.borderlessButton).frame(width: 28).help("More actions")
            }.padding(.horizontal, 10).padding(.vertical, 8)
        }.frame(width: 350, height: 400).background(.regularMaterial).environment(\.colorScheme, theme.colorScheme ?? colorScheme)
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
private struct RemoteOverview: View {
    @ObservedObject var browser: BrowserDashboard
    @ObservedObject var remote: RemoteAccessModel
    var open: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: open) {
                HStack {
                    Label("Remote workspace", systemImage: "terminal")
                    Spacer()
                    Text(browser.running ? "\(browser.sessions.count) sessions" : "Stopped").foregroundStyle(.secondary)
                }.font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain)
            CompactTunnel(tunnel: remote.tailTunnel)
            CompactTunnel(tunnel: remote.cloudTunnel)
            CompactTunnel(tunnel: remote.ngrokTunnel)
            if !remote.tailTunnel.running && !remote.cloudTunnel.running && !remote.ngrokTunnel.running {
                Text("Remote access is off").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
private struct CompactTunnel: View {
    @ObservedObject var tunnel: SharedTunnel
    var body: some View {
        if tunnel.running {
            HStack(spacing: 6) {
                Circle().fill(tunnel.ready ? Color.green : Color.orange).frame(width: 5, height: 5)
                Text(tunnel.provider?.rawValue ?? "Tunnel").font(.system(size: 10, weight: .medium))
                if let url = tunnel.url, tunnel.ready {
                    Link(url.host ?? url.absoluteString, destination: url).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.plain).help("Copy remote URL")
                } else {
                    Text(tunnel.message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
