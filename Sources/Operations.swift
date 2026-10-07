import Cocoa
import SwiftUI

// Commands run off the UI thread, with output drained before waiting and a bounded lifetime.
struct CommandResult {
    let code: Int32
    let output: String
}
enum OperationsCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 25) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/local/google-cloud-sdk/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            deadline.cancel()
            return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
        } catch { return CommandResult(code: -1, output: error.localizedDescription) }
    }
    static func quote(_ value: String) -> String { "\u{27}" + value.replacingOccurrences(of: "\u{27}", with: "\u{27}\\\u{27}\u{27}") + "\u{27}" }
}

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
    @Published var expiry: Date?
    @Published var now = Date()
    @Published var connections: [ConnectionSnapshot] = []
    @Published var statsMessage = "Checking connections…"
    @Published var project = UserDefaults.standard.string(forKey: "gcpProject") ?? ""
    @Published var gcloudPath = UserDefaults.standard.string(forKey: "gcloudPath") ?? ["/usr/local/google-cloud-sdk/bin/gcloud", "/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) ?? "/opt/homebrew/bin/gcloud"
    @Published var instances: [VMInstance] = []
    @Published var loadedProject = ""
    @Published var cloudMessage = "Enter a project ID and refresh. Uses your existing gcloud login."
    @Published var cloudBusy = false
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
            if self.ticks % 30 == 0, self.manager?.dashboardWindow?.isVisible == true, !self.loadedProject.isEmpty { self.refreshCloud() }
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
                return ConnectionSnapshot(name: name, port: port, listening: listening, sessions: sessions, available: result.code == 0 || (result.code == 1 && result.output.isEmpty))
            }
            DispatchQueue.main.async {
                self.expiry = expiry
                self.connections = snapshots
                self.statsMessage = expiry == nil ? "Teleport expiry unavailable. Check login, configured proxy, and tsh path." : "Credential expiry; existing connections may follow cluster policy."
                self.refreshing = false
            }
        }
    }
    func refreshCloud() {
        guard !cloudBusy else { return }
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty else { cloudMessage = "Enter a GCP project ID."; instances = []; loadedProject = ""; return }
        UserDefaults.standard.set(project, forKey: "gcpProject")
        UserDefaults.standard.set(gcloudPath, forKey: "gcloudPath")
        cloudBusy = true
        cloudMessage = "Loading instances…"
        let path = gcloudPath
        DispatchQueue.global(qos: .utility).async {
            let result = OperationsCommand.run(path, ["compute", "instances", "list", "--project=" + project, "--format=json", "--quiet"])
            let rows = result.code == 0 ? try? JSONDecoder().decode([VMInstance].self, from: Data(result.output.utf8)) : nil
            DispatchQueue.main.async {
                self.cloudBusy = false
                self.instances = rows ?? []
                self.loadedProject = rows == nil ? "" : project
                self.cloudMessage = rows.map { "\($0.count) instances · updated \(Date().formatted(date: .omitted, time: .standard))" } ?? "Unable to load instances: \(result.output.prefix(1200))"
            }
        }
    }
    func operate(_ action: String, instance: VMInstance) {
        guard !cloudBusy, project.trimmingCharacters(in: .whitespacesAndNewlines) == loadedProject, !loadedProject.isEmpty else { return }
        let project = loadedProject
        if action == "stop" {
            let alert = NSAlert()
            alert.messageText = "Stop \(instance.name)?"
            alert.informativeText = "Project: \(project)\nZone: \(instance.shortZone)\nThis interrupts workloads and active connections."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop Instance")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        let path = gcloudPath
        if action == "ssh" {
            let args = [path, "compute", "ssh", instance.name, "--project=" + project, "--zone=" + instance.shortZone, "--tunnel-through-iap"]
            let command = args.map(OperationsCommand.quote).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")?.executeAndReturnError(&error)
            cloudMessage = error.map { "Could not open Terminal: \($0)" } ?? "SSH opened in Terminal for \(instance.name)."
            return
        }
        cloudBusy = true
        cloudMessage = "\(action.capitalized) requested for \(instance.name)…"
        DispatchQueue.global(qos: .utility).async {
            let result = OperationsCommand.run(path, ["compute", "instances", action, instance.name, "--project=" + project, "--zone=" + instance.shortZone, "--quiet"], timeout: 180)
            DispatchQueue.main.async {
                self.cloudBusy = false
                if result.code == 0 { self.refreshCloud() }
                else { self.cloudMessage = "Operation failed or timed out; refresh to verify state. \(result.output.prefix(1200))" }
            }
        }
    }
}

struct OperationsView: View {
    @ObservedObject var model: OperationsModel
    var body: some View {
        TabView {
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
            }.padding(24).tabItem { Label("Connections", systemImage: "network") }
            VStack(alignment: .leading, spacing: 14) {
                Text("Google Cloud instances").font(.title2.bold())
                TextField("GCP project ID", text: $model.project).disabled(model.cloudBusy)
                TextField("Absolute path to gcloud", text: $model.gcloudPath).disabled(model.cloudBusy)
                HStack { Button("Refresh", action: model.refreshCloud).disabled(model.cloudBusy); if model.cloudBusy { ProgressView().controlSize(.small) } }
                Text(model.cloudMessage).font(.caption).textSelection(.enabled)
                List(model.instances) { instance in
                    HStack {
                        VStack(alignment: .leading) { Text(instance.name).bold(); Text("\(instance.shortZone) · \(instance.status)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Start") { model.operate("start", instance: instance) }.disabled(instance.status != "TERMINATED")
                        Button("Stop") { model.operate("stop", instance: instance) }.disabled(instance.status != "RUNNING")
                        Button("Connect") { model.operate("ssh", instance: instance) }.disabled(instance.status != "RUNNING")
                    }.padding(.vertical, 6)
                }.disabled(model.cloudBusy || model.project.trimmingCharacters(in: .whitespacesAndNewlines) != model.loadedProject)
                Text("Authenticate with gcloud auth login in Terminal. Connect opens SSH through IAP; IAM and firewall access are required. Status refreshes every 30 seconds while this window is open.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).tabItem { Label("Google Cloud", systemImage: "cloud") }
        }.frame(minWidth: 780, minHeight: 520)
    }
}
extension InfraProxyManager {
    @objc func showDashboard() {
        if dashboardWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 600), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "InfraProxy — Operations"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OperationsView(model: operations))
            window.center()
            dashboardWindow = window
        }
        operations.refreshStats()
        dashboardWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
