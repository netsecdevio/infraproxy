import Cocoa
import SwiftUI

struct CloudAccount: Decodable, Identifiable {
    let account: String
    let status: String
    var id: String { account }
}
struct CloudProject: Decodable, Identifiable {
    let projectId: String
    let name: String?
    let lifecycleState: String?
    var id: String { projectId }
    var label: String { name.map { "\($0) (\(projectId))" } ?? projectId }
}
enum CloudResourceKind: String, CaseIterable, Identifiable {
    case instances = "VM instances", buckets = "Storage buckets", sql = "Cloud SQL"
    case kubernetes = "Kubernetes clusters", run = "Cloud Run", networks = "VPC networks"
    var id: String { rawValue }
    var arguments: [String] {
        switch self {
        case .instances: return ["compute", "instances", "list", "--format=json(name,zone,status)"]
        case .buckets: return ["storage", "buckets", "list", "--format=json(name,location,default_storage_class)"]
        case .sql: return ["sql", "instances", "list", "--format=json(name,region,state,databaseVersion)"]
        case .kubernetes: return ["container", "clusters", "list", "--format=json(name,location,status,currentMasterVersion)"]
        case .run: return ["run", "services", "list", "--format=json(metadata.name,metadata.labels,status.conditions,status.url)"]
        case .networks: return ["compute", "networks", "list", "--format=json(name,autoCreateSubnetworks,routingConfig.routingMode)"]
        }
    }
    var consolePath: String {
        switch self {
        case .instances: return "/compute/instances"
        case .buckets: return "/storage/browser"
        case .sql: return "/sql/instances"
        case .kubernetes: return "/kubernetes/list/overview"
        case .run: return "/run"
        case .networks: return "/networking/networks/list"
        }
    }
}
struct CloudResource: Identifiable {
    let id: String
    let name: String
    let location: String
    let detail: String
    static func parse(_ data: Data, kind: CloudResourceKind) throws -> [CloudResource] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "InfraProxy", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected resource response"])
        }
        return try rows.map { row in
            let metadata = row["metadata"] as? [String: Any] ?? [:]
            guard let name = (row["name"] ?? metadata["name"]) as? String else {
                throw NSError(domain: "InfraProxy", code: 2, userInfo: [NSLocalizedDescriptionKey: "Resource is missing its name"])
            }
            let labels = metadata["labels"] as? [String: String] ?? [:]
            let location = (row["location"] as? String) ?? (row["region"] as? String) ?? labels["cloud.googleapis.com/location"] ?? "Global"
            let detail: String
            switch kind {
            case .buckets: detail = (row["default_storage_class"] as? String) ?? (row["storage_class"] as? String) ?? "Bucket"
            case .sql: detail = [row["state"], row["databaseVersion"]].compactMap { $0 as? String }.joined(separator: " · ")
            case .kubernetes: detail = [row["status"], row["currentMasterVersion"]].compactMap { $0 as? String }.joined(separator: " · ")
            case .run:
                let status = row["status"] as? [String: Any] ?? [:]
                let conditions = status["conditions"] as? [[String: Any]] ?? []
                let ready = conditions.first { $0["type"] as? String == "Ready" }?["status"] as? String
                detail = ready == "True" ? "Ready" : (ready == "False" ? "Not ready" : "Readiness unknown")
            case .networks:
                let routing = row["routingConfig"] as? [String: Any] ?? [:]
                detail = ((row["autoCreateSubnetworks"] as? Bool == true) ? "Auto subnets" : "Custom subnets") + " · " + (routing["routingMode"] as? String ?? "Routing unknown")
            case .instances: detail = row["status"] as? String ?? "Unknown"
            }
            return CloudResource(id: location + "/" + name, name: name, location: location, detail: detail)
        }
    }
}
enum CloudCommands {
    static func login(account: String?) -> [String] {
        ["auth", "login"] + (account.map { [$0] } ?? []) + ["--force", "--no-activate", "--brief", "--launch-browser"]
    }
    static func scope(account: String, project: String) -> [String] { ["--account=" + account, "--project=" + project, "--quiet"] }
    static func consoleURL(path: String, account: String, project: String) -> URL {
        var url = URLComponents()
        url.scheme = "https"
        url.host = "console.cloud.google.com"
        url.path = path
        url.queryItems = [URLQueryItem(name: "project", value: project), URLQueryItem(name: "authuser", value: account)]
        return url.url!
    }
    static func discoverSDK(saved: String?) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [saved].compactMap { $0 } + ["/usr/local/google-cloud-sdk/bin/gcloud", "/opt/homebrew/bin/gcloud", "/usr/local/bin/gcloud", home + "/google-cloud-sdk/bin/gcloud", home + "/.local/google-cloud-sdk/bin/gcloud"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/gcloud" }
        return paths.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class GoogleCloudModel: ObservableObject {
    typealias Runner = (String, [String], TimeInterval, CommandControl?) -> CommandResult
    @Published private(set) var accounts: [CloudAccount] = []
    @Published private(set) var projects: [CloudProject] = []
    @Published private(set) var account = ""
    @Published private(set) var project = ""
    @Published private(set) var kind: CloudResourceKind = .instances
    @Published private(set) var instances: [VMInstance] = []
    @Published private(set) var resources: [CloudResource] = []
    @Published private(set) var sdkPath: String?
    @Published private(set) var busy = false
    @Published private(set) var authenticating = false
    @Published private(set) var message = "Discovering Google Cloud accounts…"
    @Published private(set) var identityMessage = ""
    @Published private(set) var loadedScope = ""
    private var discovered = false
    private var authControl: CommandControl?
    private let defaults: UserDefaults
    private let run: Runner
    private let resolveSDK: (String?) -> String?
    var scope: String { account + "/" + project + "/" + kind.rawValue }
    var canOperate: Bool { !busy && !account.isEmpty && !project.isEmpty && loadedScope == scope }
    init(defaults: UserDefaults = .standard, sdkResolver: @escaping (String?) -> String? = CloudCommands.discoverSDK, runner: @escaping Runner = { OperationsCommand.run($0, $1, timeout: $2, control: $3) }) {
        self.defaults = defaults
        self.run = runner
        self.resolveSDK = sdkResolver
        sdkPath = sdkResolver(defaults.string(forKey: "gcloudPath"))
    }
    func discoverIfNeeded() { if !discovered { discover() } }
    private func clearResources() { instances = []; resources = []; loadedScope = "" }
    func discover(preferredAccount: String? = nil) {
        guard !busy else { return }
        sdkPath = resolveSDK(defaults.string(forKey: "gcloudPath"))
        guard let path = sdkPath else { message = "Google Cloud CLI is not installed or could not be found. Install it, or locate an existing installation."; return }
        discovered = true
        busy = true
        clearResources()
        message = "Discovering accounts…"
        let preferred = preferredAccount ?? (account.isEmpty ? defaults.string(forKey: "gcpAccount") : account)
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(path, ["auth", "list", "--format=json(account,status)", "--quiet"], 25, nil)
            let rows = result.code == 0 ? try? JSONDecoder().decode([CloudAccount].self, from: Data(result.output.utf8)) : nil
            let config = self.run(path, ["config", "get-value", "project", "--quiet"], 10, nil)
            let defaultProject = config.code == 0 ? config.output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            DispatchQueue.main.async {
                self.busy = false
                self.accounts = rows ?? []
                self.projects = []
                self.project = ""
                self.account = rows?.first(where: { $0.account == preferred })?.account ?? rows?.first(where: { $0.status == "ACTIVE" })?.account ?? rows?.first?.account ?? ""
                guard rows != nil else { self.message = "Could not read accounts. \(result.diagnostic.prefix(800))"; return }
                guard !self.account.isEmpty else { self.message = "Sign in with Google to discover your projects."; self.identityMessage = "No accounts connected"; return }
                self.loadProjects(defaultProject: defaultProject)
            }
        }
    }
    func selectAccount(_ value: String) {
        guard !busy, accounts.contains(where: { $0.account == value }) else { return }
        account = value
        projects = []
        project = ""
        clearResources()
        loadProjects()
    }
    private func loadProjects(defaultProject: String = "") {
        guard !busy, let path = sdkPath, !account.isEmpty else { return }
        busy = true
        let account = account
        defaults.set(account, forKey: "gcpAccount")
        message = "Discovering accessible projects…"
        identityMessage = "Checking access for \(account)…"
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(path, ["projects", "list", "--account=" + account, "--format=json(projectId,name,lifecycleState)", "--quiet"], 60, nil)
            let rows = result.code == 0 ? try? JSONDecoder().decode([CloudProject].self, from: Data(result.output.utf8)) : nil
            DispatchQueue.main.async {
                self.busy = false
                self.projects = (rows ?? []).filter { $0.lifecycleState == nil || $0.lifecycleState == "ACTIVE" }.sorted { $0.label < $1.label }
                guard rows != nil else {
                    self.project = ""
                    self.clearResources()
                    self.identityMessage = "Could not verify project access"
                    self.message = "Project discovery failed. Reauthenticate if your login expired, or check project-list permissions. \(result.diagnostic.prefix(800))"
                    return
                }
                let preferred = self.defaults.string(forKey: "gcpProject." + account) ?? self.defaults.string(forKey: "gcpProject") ?? defaultProject
                self.project = self.projects.first(where: { $0.projectId == preferred })?.projectId ?? self.projects.first(where: { $0.projectId == defaultProject })?.projectId ?? self.projects.first?.projectId ?? ""
                self.identityMessage = "\(self.projects.count) accessible projects · Credentials managed by Google Cloud CLI"
                if self.project.isEmpty { self.message = "No accessible active projects were returned for this account." }
                else { self.refreshResources() }
            }
        }
    }
    func selectProject(_ value: String) {
        guard !busy, projects.contains(where: { $0.projectId == value }) else { return }
        project = value
        clearResources()
        refreshResources()
    }
    func selectKind(_ value: CloudResourceKind) {
        guard !busy else { return }
        kind = value
        clearResources()
        refreshResources()
    }
    func refreshResources() {
        guard !busy, let path = sdkPath, !account.isEmpty, !project.isEmpty else { return }
        busy = true
        clearResources()
        let account = account, project = project, kind = kind, scope = scope
        defaults.set(project, forKey: "gcpProject." + account)
        message = "Loading \(kind.rawValue.lowercased())…"
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(path, kind.arguments + CloudCommands.scope(account: account, project: project), 60, nil)
            var instances: [VMInstance] = []
            var resources: [CloudResource] = []
            var error: String?
            if result.code == 0 {
                do {
                    if kind == .instances { instances = try JSONDecoder().decode([VMInstance].self, from: Data(result.output.utf8)) }
                    else { resources = try CloudResource.parse(Data(result.output.utf8), kind: kind) }
                } catch let decodingError { error = decodingError.localizedDescription }
            } else { error = String(result.diagnostic.prefix(1000)) }
            DispatchQueue.main.async {
                self.busy = false
                guard self.scope == scope else { return }
                self.instances = instances
                self.resources = resources
                if let error { self.message = "Unable to load \(kind.rawValue.lowercased()). Check sign-in, IAM access, and whether the service API is enabled. \(error)" }
                else {
                    self.loadedScope = scope
                    let count = kind == .instances ? instances.count : resources.count
                    self.message = "\(count) \(kind.rawValue.lowercased()) · updated \(Date().formatted(date: .omitted, time: .standard))"
                }
            }
        }
    }
    func login(reauthenticate: Bool = false) {
        guard !busy, let path = sdkPath else { return }
        let requestedAccount = reauthenticate && !account.isEmpty ? account : nil
        let existingAccounts = Set(accounts.map(\.account))
        let control = CommandControl()
        authControl = control
        busy = true
        authenticating = true
        clearResources()
        message = "Complete sign-in in your browser. Google or your organization will offer the available passkey, security-key, password, and verification options."
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(path, CloudCommands.login(account: requestedAccount), 600, control)
            // Never log login output: it can contain authorization URLs and codes.
            var preferred = requestedAccount
            if result.code == 0 && preferred == nil {
                let listed = self.run(path, ["auth", "list", "--format=json(account,status)", "--quiet"], 25, nil)
                if let rows = try? JSONDecoder().decode([CloudAccount].self, from: Data(listed.output.utf8)) {
                    preferred = rows.first(where: { !existingAccounts.contains($0.account) })?.account
                }
            }
            DispatchQueue.main.async {
                self.authControl = nil
                self.authenticating = false
                self.busy = false
                if result.code == 0 && !control.isCancelled { self.discover(preferredAccount: preferred) }
                else { self.message = control.isCancelled ? "Sign-in cancelled or timed out. You can try again." : "Sign-in did not complete. Retry in your browser, or check your organization's Google Cloud login configuration." }
            }
        }
    }
    func cancelLogin() { authControl?.cancel(); message = "Cancelling sign-in…" }
    func locateSDK() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Locate Google Cloud CLI"
        panel.message = "Select the gcloud executable in your Google Cloud SDK installation."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == "gcloud", FileManager.default.isExecutableFile(atPath: url.path) else { message = "Select an executable named gcloud."; return }
        defaults.set(url.path, forKey: "gcloudPath")
        discover()
    }
    func openConsole(path: String? = nil) {
        guard !project.isEmpty else { return }
        NSWorkspace.shared.open(CloudCommands.consoleURL(path: path ?? kind.consolePath, account: account, project: project))
    }
    func operate(_ action: String, instance: VMInstance) {
        guard canOperate, let path = sdkPath, ["start", "stop", "ssh"].contains(action), instances.contains(where: { $0.id == instance.id }) else { return }
        guard action == "start" ? instance.status == "TERMINATED" : instance.status == "RUNNING" else { return }
        let account = account, project = project
        if action == "stop" {
            let alert = NSAlert()
            alert.messageText = "Stop \(instance.name)?"
            alert.informativeText = "Account: \(account)\nProject: \(project)\nZone: \(instance.shortZone)\nThis interrupts workloads and active connections."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Stop Instance")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        if action == "ssh" {
            let args = [path, "compute", "ssh", instance.name, "--account=" + account, "--project=" + project, "--zone=" + instance.shortZone, "--tunnel-through-iap"]
            let command = args.map(OperationsCommand.quote).joined(separator: " ")
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"Terminal\"\nactivate\ndo script \"\(escaped)\"\nend tell")
            script?.executeAndReturnError(&error)
            message = error != nil || script == nil ? "Could not open Terminal. Check the macOS Automation permission for InfraProxy." : "SSH opened in Terminal for \(instance.name)."
            return
        }
        busy = true
        message = "\(action.capitalized) requested for \(instance.name)…"
        DispatchQueue.global(qos: .utility).async {
            let result = self.run(path, ["compute", "instances", action, instance.name, "--zone=" + instance.shortZone] + CloudCommands.scope(account: account, project: project), 180, nil)
            DispatchQueue.main.async {
                self.busy = false
                if result.code == 0 { self.refreshResources() }
                else { self.clearResources(); self.message = "Operation failed or timed out; refresh to verify state. \(result.diagnostic.prefix(1000))" }
            }
        }
    }
}

struct GoogleCloudView: View {
    @ObservedObject var model: GoogleCloudModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Google Cloud").font(.title2.bold())
                Spacer()
                if model.authenticating { Button("Cancel sign-in", action: model.cancelLogin) }
                else {
                    Button("Sign in / Add account") { model.login() }.disabled(model.busy || model.sdkPath == nil)
                    Button("Reauthenticate") { model.login(reauthenticate: true) }.disabled(model.busy || model.account.isEmpty)
                }
            }
            Text("Sign in securely in your browser using the methods offered by Google or your organization, including supported passkeys and hardware security keys.").font(.caption).foregroundStyle(.secondary)
            if model.sdkPath == nil {
                HStack {
                    Link("Install Google Cloud CLI", destination: URL(string: "https://cloud.google.com/sdk/docs/install")!)
                    Button("Locate gcloud…", action: model.locateSDK)
                    Button("Check again") { model.discover() }
                }
            } else {
                HStack {
                    Picker("Account", selection: Binding(get: { model.account }, set: model.selectAccount)) {
                        if model.account.isEmpty { Text("Sign in to add an account").tag("") }
                        ForEach(model.accounts) { Text($0.account).tag($0.account) }
                    }
                    Button("Reload accounts & projects") { model.discover() }
                }.disabled(model.busy)
                Text(model.identityMessage).font(.caption).foregroundStyle(.secondary)
                Picker("Project", selection: Binding(get: { model.project }, set: model.selectProject)) {
                    if model.project.isEmpty { Text("No project available").tag("") }
                    ForEach(model.projects) { Text($0.label).tag($0.projectId) }
                }.disabled(model.busy || model.projects.isEmpty)
                HStack {
                    Picker("Resources", selection: Binding(get: { model.kind }, set: model.selectKind)) {
                        ForEach(CloudResourceKind.allCases) { Text($0.rawValue).tag($0) }
                    }.frame(maxWidth: 320)
                    Button("Refresh", action: model.refreshResources)
                    Spacer()
                    Menu("Cloud Console") {
                        Button("Current resources") { model.openConsole() }
                        Button("Project overview") { model.openConsole(path: "/home/dashboard") }
                        Button("Logs Explorer") { model.openConsole(path: "/logs/query") }
                        Button("IAM & access") { model.openConsole(path: "/iam-admin/iam") }
                        Button("Enabled APIs") { model.openConsole(path: "/apis/dashboard") }
                    }
                }.disabled(model.busy || model.project.isEmpty)
            }
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).font(.caption).textSelection(.enabled).lineLimit(5)
            }
            if model.kind == .instances {
                List(model.instances) { instance in
                    HStack {
                        VStack(alignment: .leading) { Text(instance.name).bold(); Text("\(instance.shortZone) · \(instance.status)").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Start") { model.operate("start", instance: instance) }.disabled(instance.status != "TERMINATED")
                        Button("Stop") { model.operate("stop", instance: instance) }.disabled(instance.status != "RUNNING")
                        Button("Connect") { model.operate("ssh", instance: instance) }.disabled(instance.status != "RUNNING")
                    }.padding(.vertical, 6)
                }.disabled(!model.canOperate)
            } else {
                List(model.resources) { resource in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(resource.name).bold(); Text(resource.location).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Text(resource.detail).font(.caption)
                    }.padding(.vertical, 6)
                }
            }
            HStack {
                Text("Resources refresh every 30 seconds. VM connections use SSH through IAP. Other resources are read-only; open Cloud Console for more operations.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu("CLI setup") {
                    if let path = model.sdkPath { Text(path) }
                    Button("Locate gcloud…", action: model.locateSDK)
                    Button("Detect again") { model.discover() }
                }.disabled(model.busy)
            }
        }.padding(24).onAppear { model.discoverIfNeeded() }
    }
}
