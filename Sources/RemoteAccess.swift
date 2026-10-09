import Cocoa
import SwiftUI
import Combine

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
    case tailscale = "Tailscale Serve", funnel = "Tailscale Funnel", cloudflare = "Cloudflare", ngrok = "ngrok"
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
        case .ngrok: return ["http", target, "--log=stdout", "--log-format=json", "--log-level=info", "--inspect=false"]
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
        if provider == .ngrok {
            return output.split(separator: "\n").compactMap { line -> URL? in
                guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], row["msg"] as? String == "started tunnel",
                      let value = row["url"] as? String, let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
                return url
            }.last
        }
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
    @Published private(set) var localPort: Int?
    private var process: Process?
    private var control: CommandControl?
    private var output = ""
    private var startupTimeout: DispatchWorkItem?
    private var timedOut = false
    func start(executable: String, arguments: [String], provider: RemoteProvider, localPort: Int? = nil) {
        guard process == nil else { return }
        self.provider = provider
        self.localPort = localPort
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
                } else if provider == .ngrok { self.ready = self.url != nil }
                else if self.url != nil && self.output.contains("Press Ctrl+C") { self.ready = true }
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
                self.localPort = nil
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
    @Published private(set) var ngrokPath: String?
    @Published private(set) var ngrokMessage = "Checking ngrok…"
    @Published private(set) var refreshing = false
    @Published var localPort = ""
    @Published private(set) var preparing = false
    @Published var error: String?
    let tailTunnel = SharedTunnel()
    let cloudTunnel = SharedTunnel()
    let ngrokTunnel = SharedTunnel()
    var readyURLs: [URL] { [tailTunnel, cloudTunnel, ngrokTunnel].filter(\.ready).compactMap(\.url) }
    func stopDashboardTunnels(port: Int) { generation += 1; preparing = false; for tunnel in [tailTunnel, cloudTunnel, ngrokTunnel] where tunnel.localPort == port { tunnel.stop() } }
    private var timer: Timer?
    private var generation = 0
    private var tunnelChanges = Set<AnyCancellable>()
    init() {
        for tunnel in [tailTunnel, cloudTunnel, ngrokTunnel] {
            tunnel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tunnelChanges)
        }
    }
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
        let ngrok = RemoteCommands.executable("ngrok")
        ngrokPath = ngrok
        DispatchQueue.global(qos: .utility).async {
            let ngrokConfig = ngrok.map { OperationsCommand.run($0, ["config", "check"], timeout: 5) }
            let result = tail.map { OperationsCommand.run($0, ["status", "--json"], timeout: 5) }
            let status = result?.code == 0 ? try? JSONDecoder().decode(TailStatus.self, from: Data((result?.output ?? "").utf8)) : nil
            DispatchQueue.main.async {
                self.ngrokMessage = ngrok == nil ? "Not installed" : ngrokConfig?.code == 0 ? "Agent configuration available" : "Complete ngrok account setup"
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
        let tunnel = provider == .cloudflare ? cloudTunnel : provider == .ngrok ? ngrokTunnel : tailTunnel
        guard !tunnel.running else { return }
        guard let path = provider == .cloudflare ? cloudflarePath : provider == .ngrok ? ngrokPath : tailscalePath else { error = "Install the provider's command-line tool first."; return }
        guard (provider == .cloudflare || provider == .ngrok) || tailscale?.connected == true else { error = "Connect Tailscale first."; return }
        let alert = NSAlert()
        alert.messageText = provider.isPublic ? "Share this service publicly?" : "Share this service with your tailnet?"
        alert.informativeText = "\(provider.rawValue) will expose http://127.0.0.1:\(port). " + (provider.isPublic ? "People on the Internet with the URL can reach it; your web service must provide its own authentication." : "Access follows your Tailscale policy.") + " Stop sharing here to close this tunnel."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Start Sharing")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        preparing = true
        let requestedGeneration = generation
        DispatchQueue.global(qos: .utility).async {
            var failure: String?
            if provider == .tailscale || provider == .funnel {
                let status = OperationsCommand.run(path, ["serve", "status", "--json"], timeout: 5)
                if status.code != 0 { failure = "Could not verify existing Tailscale Serve configuration." }
                else {
                    do { if try RemoteCommands.portInUse(status.output) { failure = "Tailscale HTTPS port 8443 is already in use. Existing shares have been preserved." } }
                    catch { failure = "Unrecognized Tailscale Serve configuration; no changes were made." }
                }
            } else if provider == .cloudflare {
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cloudflared")
                if ["config.yml", "config.yaml"].contains(where: { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
                    failure = "An existing Cloudflare tunnel configuration is present. Manage that tunnel in Cloudflare; Quick Tunnel setup will not modify it."
                }
            }
            if provider == .ngrok, OperationsCommand.run(path, ["config", "check"], timeout: 5).code != 0 { failure = "Complete ngrok agent setup in your account dashboard, then refresh. Existing configuration was not changed." }
            let errorMessage = failure
            DispatchQueue.main.async {
                guard self.generation == requestedGeneration else { return }
                self.preparing = false
                if let errorMessage { self.error = errorMessage; return }
                tunnel.start(executable: path, arguments: RemoteCommands.arguments(provider, port: port), provider: provider, localPort: port)
            }
        }
    }
    func shutdown() { generation += 1; preparing = false; timer?.invalidate(); tailTunnel.stop(); cloudTunnel.stop(); ngrokTunnel.stop() }
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
    @ObservedObject var browser: BrowserDashboard
    @State private var provider: RemoteProvider = .tailscale
    @State private var targetDashboard = true
    @State private var confirmRotation = false
    private var blockedPorts: Set<Int> { Set([Int(manager.configuration.teleport.localPort), Int(manager.configuration.httpProxy.port)].compactMap { $0 }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("Authentication") {
                    LabeledContent("Authentication method", value: "Rotating access key")
                    Text("Every browser connection needs the key, including localhost and provider tunnels. Browser sessions expire after 8 hours. Anyone with the key can open a shell as your Mac user.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Copy access key", action: browser.copyKey).disabled(!browser.running)
                        Button("Rotate key…") { confirmRotation = true }.disabled(!browser.running)
                        Spacer()
                        Button("Open local browser", action: browser.openBrowser).disabled(!browser.running)
                    }
                }
                SettingsSection("Inbound destination") {
                    Picker("Forward incoming traffic to", selection: $targetDashboard) {
                        Text("InfraProxy dashboard & terminal").tag(true)
                        Text("Another local web service").tag(false)
                    }
                    if targetDashboard {
                        HStack { Text(browser.localURL?.absoluteString ?? "Browser server is stopped").font(.system(.caption, design: .monospaced)); Spacer(); if !browser.running { Button("Start browser server", action: browser.start).disabled(browser.starting) } }
                    } else { TextField("Local service port, e.g. 3000", text: $model.localPort).frame(width: 220) }
                    Text("Remote browser → provider tunnel → this Mac. Teleport SOCKS and HTTP forward proxies remain outbound connections in the Outbound tab.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("Tailscale integration") {
                    HStack { Label(model.tailMessage, systemImage: "circle.fill").foregroundStyle(model.tailscale?.connected == true ? .green : .secondary); Spacer(); Button("Open Tailscale", action: model.openTailscale) }
                    Picker("Access", selection: $provider) { Text("Private · tailnet only").tag(RemoteProvider.tailscale); Text("Public · Funnel").tag(RemoteProvider.funnel) }.pickerStyle(.segmented)
                    HStack { Text("Incoming HTTPS on port 8443").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Start inbound access…") { share(provider) }.disabled(model.preparing || model.tailTunnel.running || (targetDashboard && !browser.running)) }
                    TunnelControls(title: "Tailscale", tunnel: model.tailTunnel)
                    Text("Private Serve access follows your tailnet policy. The InfraProxy browser key is still required.").font(.caption).foregroundStyle(.secondary)
                }
                SettingsSection("ngrok integration") {
                    HStack { Text(model.ngrokMessage); Spacer(); Link("Account setup", destination: URL(string: "https://dashboard.ngrok.com/get-started/setup/macos")!) }
                    Text("Uses your installed ngrok agent and its existing account configuration. Public inbound HTTPS; request inspection is disabled.").font(.caption).foregroundStyle(.secondary)
                    HStack { TunnelControls(title: "ngrok", tunnel: model.ngrokTunnel); Spacer(); Button("Start ngrok…") { share(.ngrok) }.disabled(model.preparing || model.ngrokTunnel.running || (targetDashboard && !browser.running)) }
                }
                SettingsSection("Cloudflare integration") {
                    HStack { Text(model.cloudflarePath == nil ? "Install cloudflared to get started" : "Cloudflare Quick Tunnel available"); Spacer(); Link("Provider setup", destination: URL(string: "https://developers.cloudflare.com/tunnel/get-started/quick-tunnels/")!) }
                    Text("Creates a temporary public inbound URL. Existing named tunnel configuration is preserved.").font(.caption).foregroundStyle(.secondary)
                    HStack { TunnelControls(title: "Cloudflare", tunnel: model.cloudTunnel); Spacer(); Button("Start Quick Tunnel…") { share(.cloudflare) }.disabled(model.preparing || model.cloudTunnel.running || (targetDashboard && !browser.running)) }
                }
                HStack { Text("Tailnet devices").font(.headline); Spacer(); Button("Refresh providers", action: model.refresh).disabled(model.refreshing) }
                ForEach(model.tailscale?.peers ?? []) { peer in
                    HStack { Circle().fill(peer.Online == true ? Color.green : Color.secondary).frame(width: 7, height: 7); Text(peer.name); Spacer(); Text(peer.address).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }.padding(.horizontal, 8)
                }
            }.padding(28)
        }
        .alert("Inbound access", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("Rotate browser access key?", isPresented: $confirmRotation) { Button("Cancel", role: .cancel) {}; Button("Rotate and disconnect", role: .destructive, action: browser.rotateKey) } message: { Text("All browser logins and terminals will be disconnected. Sign in again with the new key.") }
    }
    private func share(_ provider: RemoteProvider) {
        if targetDashboard { guard browser.running else { return }; model.localPort = String(browser.activePort) }
        model.share(provider, blockedPorts: blockedPorts)
    }
}
