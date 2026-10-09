import Cocoa
import SwiftUI

struct TailPeer: Decodable, Identifiable {
    let nodeID: String?
    enum CodingKeys: String, CodingKey { case nodeID = "ID", HostName, DNSName, TailscaleIPs, Online }
    let HostName: String?
    let DNSName: String?
    let TailscaleIPs: [String]?
    let Online: Bool?
    var id: String { nodeID ?? DNSName ?? HostName ?? address }
    var name: String { HostName ?? DNSName ?? "Device" }
    var address: String { TailscaleIPs?.first ?? "" }
}
struct TailStatus: Decodable {
    let backendState: String
    let selfNode: TailPeer?
    let peerMap: [String: TailPeer]?
    enum CodingKeys: String, CodingKey { case backendState = "BackendState", selfNode = "Self", peerMap = "Peer" }
    var connected: Bool { backendState == "Running" }
    var hostname: String { selfNode?.DNSName?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "" }
    var peers: [TailPeer] { (peerMap ?? [:]).values.sorted { ($0.Online == true ? 0 : 1, $0.name) < ($1.Online == true ? 0 : 1, $1.name) } }
}
enum RemoteProvider: String, CaseIterable, Identifiable {
    case tailscale = "Tailscale Serve", funnel = "Tailscale Funnel", cloudflare = "Cloudflare"
    var id: String { rawValue }
    var isPublic: Bool { self != .tailscale }
}
enum RemoteCommands {
    static func executable(_ name: String) -> String? {
        var candidates = ["/opt/homebrew/bin/" + name, "/usr/local/bin/" + name]
        if name == "tailscale" { candidates.insert("/Applications/Tailscale.app/Contents/MacOS/Tailscale", at: 0) }
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/" + name }
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func port(_ text: String, blocked: Set<Int>) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), let port = Int(text), (1...65535).contains(port), !blocked.contains(port) else { return nil }
        return port
    }
    static func arguments(_ provider: RemoteProvider, port: Int) -> [String] {
        let target = "http://127.0.0.1:\(port)"
        switch provider {
        case .tailscale: return ["serve", "--https=8443", target]
        case .funnel: return ["funnel", "--https=8443", target]
        case .cloudflare: return ["tunnel", "--no-autoupdate", "--url", target]
        }
    }
    static func portInUse(_ json: String) throws -> Bool {
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        if root is NSNull { return false }
        guard let config = root as? [String: Any] else { throw NSError(domain: "RemoteAccess", code: 1) }
        // Foreground Serve sessions can be nested under Foreground in current clients.
        func occupied(_ object: [String: Any]) -> Bool {
            if (object["TCP"] as? [String: Any])?["8443"] != nil { return true }
            if (object["Web"] as? [String: Any])?.keys.contains(where: { $0.hasSuffix(":8443") }) == true { return true }
            return (object["Foreground"] as? [String: [String: Any]] ?? [:]).values.contains(where: occupied)
        }
        return occupied(config)
    }
    static func endpoint(in output: String, provider: RemoteProvider) -> URL? {
        let pattern = provider == .cloudflare ? #"https://[a-z0-9]+(?:-[a-z0-9]+)*\.trycloudflare\.com(?=[\s/]|$)"# : #"https://[a-zA-Z0-9.-]+\.ts\.net:8443(?=[\s/]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)), let range = Range(match.range, in: output) else { return nil }
        return URL(string: String(output[range]))
    }
}

// Own only the foreground process started here. Never kill or reset another app's tunnels.
final class SharedTunnel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var ready = false
    @Published private(set) var url: URL?
    @Published private(set) var message = "Not sharing"
    @Published private(set) var provider: RemoteProvider?
    private var process: Process?
    private var control: CommandControl?
    private var output = ""
    private var startupTimeout: DispatchWorkItem?
    private var timedOut = false
    func start(executable: String, arguments: [String], provider: RemoteProvider) {
        guard process == nil else { return }
        self.provider = provider
        timedOut = false
        ready = false
        url = nil
        output = ""
        message = "Starting…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let control = CommandControl()
        self.process = process
        self.control = control
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let chunk = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.process === process else { return }
                self.output = String((self.output + chunk).suffix(16000))
                if let endpoint = RemoteCommands.endpoint(in: self.output, provider: provider) { self.url = endpoint }
                if provider == .cloudflare {
                    if chunk.contains("failed to serve tunnel connection") { self.ready = false; self.message = "Reconnecting…" }
                    if self.url != nil && chunk.contains("Registered tunnel connection") { self.ready = true }
                } else if self.url != nil && self.output.contains("Press Ctrl+C") { self.ready = true }
                if self.ready { self.message = provider.isPublic ? "Public sharing" : "Private tailnet sharing"; self.startupTimeout?.cancel() }
            }
        }
        process.terminationHandler = { [weak self] ended in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self, self.process === ended else { return }
                self.process = nil
                self.control = nil
                self.running = false
                self.ready = false
                self.url = nil
                self.startupTimeout?.cancel()
                self.message = self.timedOut ? "Setup timed out. Check provider permissions or tunnel configuration." : control.isCancelled ? "Stopped" : "Tunnel exited (\(ended.terminationStatus)). Check provider access and the local service."
            }
        }
        do {
            try process.run()
            control.attach(process)
            running = true
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.process === process, !self.ready else { return }
                self.timedOut = true
                self.stop()
                self.message = "Setup timed out. Check the provider's HTTPS/Funnel permissions or tunnel configuration."
            }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: timeout)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil
            self.control = nil
            message = "Could not start: \(error.localizedDescription)"
        }
    }
    func stop() { startupTimeout?.cancel(); control?.cancel(); ready = false; url = nil; message = "Stopping…" }
}

final class RemoteAccessModel: ObservableObject {
    @Published private(set) var tailscale: TailStatus?
    @Published private(set) var tailMessage = "Checking Tailscale…"
    @Published private(set) var tailscalePath: String?
    @Published private(set) var cloudflarePath: String?
    @Published private(set) var refreshing = false
    @Published var localPort = ""
    @Published private(set) var preparing = false
    @Published var error: String?
    let tailTunnel = SharedTunnel()
    let cloudTunnel = SharedTunnel()
    private var timer: Timer?
    func start() {
        refresh()
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate() }
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let tail = RemoteCommands.executable("tailscale")
        tailscalePath = tail
        cloudflarePath = RemoteCommands.executable("cloudflared")
        DispatchQueue.global(qos: .utility).async {
            let result = tail.map { OperationsCommand.run($0, ["status", "--json"], timeout: 5) }
            let status = result?.code == 0 ? try? JSONDecoder().decode(TailStatus.self, from: Data((result?.output ?? "").utf8)) : nil
            DispatchQueue.main.async {
                self.tailscale = status
                self.tailMessage = tail == nil ? "Not installed" : (status.map { $0.connected ? "Connected" : $0.backendState } ?? "Unavailable — open Tailscale to connect")
                self.refreshing = false
            }
        }
    }
    func openTailscale() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos") ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if FileManager.default.fileExists(atPath: "/Applications/Tailscale.app") {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Tailscale.app"), configuration: NSWorkspace.OpenConfiguration())
        } else { NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!) }
    }
    func share(_ provider: RemoteProvider, blockedPorts: Set<Int>) {
        guard !preparing, let port = RemoteCommands.port(localPort, blocked: blockedPorts) else {
            error = "Choose a local web service port (1–65535). Configured SOCKS and HTTP proxy ports cannot be shared."; return
        }
        let tunnel = provider == .cloudflare ? cloudTunnel : tailTunnel
        guard !tunnel.running else { return }
        guard let path = provider == .cloudflare ? cloudflarePath : tailscalePath else { error = "Install the provider's command-line tool first."; return }
        guard provider == .cloudflare || tailscale?.connected == true else { error = "Connect Tailscale first."; return }
        let alert = NSAlert()
        alert.messageText = provider.isPublic ? "Share this service publicly?" : "Share this service with your tailnet?"
        alert.informativeText = "\(provider.rawValue) will expose http://127.0.0.1:\(port). " + (provider.isPublic ? "People on the Internet with the URL can reach it; your web service must provide its own authentication." : "Access follows your Tailscale policy.") + " Stop sharing here to close this tunnel."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Sharing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        preparing = true
        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            if provider != .cloudflare {
                let status = OperationsCommand.run(path, ["serve", "status", "--json"], timeout: 5)
                if status.code != 0 { failure = "Could not verify existing Tailscale Serve configuration." }
                else {
                    do { if try RemoteCommands.portInUse(status.output) { failure = "Tailscale HTTPS port 8443 is already in use. Existing shares have been preserved." } }
                    catch { failure = "Unrecognized Tailscale Serve configuration; no changes were made." }
                }
            } else {
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared")
                if ["config.yml", "config.yaml"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    failure = "An existing Cloudflare tunnel configuration is present. Manage that tunnel in Cloudflare; Quick Tunnel setup will not modify it."
                }
            }
            let errorMessage = failure
            DispatchQueue.main.async {
                self.preparing = false
                if let errorMessage { self.error = errorMessage; return }
                tunnel.start(executable: path, arguments: RemoteCommands.arguments(provider, port: port), provider: provider)
            }
        }
    }
    func shutdown() { timer?.invalidate(); tailTunnel.stop(); cloudTunnel.stop() }
}

struct TunnelControls: View {
    let title: String
    @ObservedObject var tunnel: SharedTunnel
    var body: some View {
        if tunnel.running {
            HStack {
                Text(tunnel.message).foregroundStyle(tunnel.ready ? .green : .secondary)
                Spacer()
                if let url = tunnel.url, tunnel.ready { Link("Open", destination: url); Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } }
                Button("Stop", action: tunnel.stop)
            }.font(.caption)
        } else { Text("\(title) · \(tunnel.message)").font(.caption).foregroundStyle(.secondary) }
    }
}
struct RemoteAccessView: View {
    @ObservedObject var model: RemoteAccessModel
    @ObservedObject var manager: InfraProxyManager
    @State private var provider: RemoteProvider = .tailscale
    private var blockedPorts: Set<Int> { Set([Int(manager.configuration.teleport.localPort), Int(manager.configuration.httpProxy.port)].compactMap { $0 }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Remote access", systemImage: "network").font(.title2.bold())
                Spacer()
                Button("Refresh", action: model.refresh).disabled(model.refreshing)
            }
            HStack {
                VStack(alignment: .leading) { Text("Tailscale · \(model.tailMessage)").bold(); Text(model.tailscale?.hostname ?? "").font(.caption).textSelection(.enabled) }
                Spacer()
                Button("Open Tailscale", action: model.openTailscale)
                Link("Admin console", destination: URL(string: "https://login.tailscale.com/admin/machines")!)
            }
            GroupBox("Share a local web service") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Local port, e.g. 3000", text: $model.localPort).frame(width: 180)
                        Picker("Via", selection: $provider) { ForEach(RemoteProvider.allCases) { Text($0.rawValue + ($0.isPublic ? " · Public" : " · Private")).tag($0) } }
                        Button("Share…") { model.share(provider, blockedPorts: blockedPorts) }.disabled(model.preparing)
                    }
                    Text("Serve stays within your tailnet. Funnel and Cloudflare Quick Tunnels create public URLs. Share a web application, not an infrastructure proxy.").font(.caption).foregroundStyle(.secondary)
                    TunnelControls(title: "Tailscale", tunnel: model.tailTunnel)
                    TunnelControls(title: "Cloudflare", tunnel: model.cloudTunnel)
                    if model.cloudflarePath == nil { Link("Install cloudflared", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/downloads/")!) }
                    Link("Manage Cloudflare tunnels", destination: URL(string: "https://one.dash.cloudflare.com/")!)
                }.padding(8)
            }
            Text("Tailnet devices").font(.headline)
            List(model.tailscale?.peers ?? []) { peer in
                HStack {
                    Circle().fill(peer.Online == true ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    VStack(alignment: .leading) { Text(peer.name).bold(); Text(peer.address).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(peer.Online == true ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary)
                    Button("Copy IP") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(peer.address, forType: .string) }.disabled(peer.address.isEmpty)
                }.padding(.vertical, 4)
            }
        }.padding(24).alert("Remote access", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
