// Native adaptation of Barklarm observers. See Vendor/BARKLARM.md and third-party notices.
import Cocoa
import SwiftUI
import Security
import UserNotifications

struct DevOpsMonitor: Codable, Identifiable {
    var id = UUID()
    var type: String
    var fields: [String: String]
    var muted = false
    var name: String { fields["alias"].flatMap { $0.isEmpty ? nil : $0 } ?? DevOpsProvider.title(type) }
}
enum DevOpsProvider {
    static let types = ["githubAction", "azureDevOps", "bitbucket", "ccTray", "datadogMonitor", "sentry", "newRelic", "opsgenie", "graylog", "grafana"]
    static func title(_ type: String) -> String {
        ["githubAction":"GitHub Actions", "azureDevOps":"Azure DevOps", "bitbucket":"Bitbucket Pipelines", "ccTray":"CCTray", "datadogMonitor":"Datadog", "sentry":"Sentry", "newRelic":"New Relic", "opsgenie":"Opsgenie", "graylog":"Graylog", "grafana":"Grafana"][type] ?? type
    }
    static func fields(_ type: String) -> [String] {
        switch type {
        case "githubAction": return ["owner", "repo", "workflowId", "authToken"]
        case "azureDevOps": return ["orgUrl", "project", "pipelineId", "authToken"]
        case "bitbucket": return ["workspace", "repo", "branch", "authToken"]
        case "ccTray": return ["url", "name"]
        case "datadogMonitor": return ["site", "monitorId", "apiKey", "appKey"]
        case "sentry": return ["organization", "project", "authToken"]
        case "newRelic": return ["site", "apiKey"]
        case "opsgenie": return ["host", "identifier", "apiKey"]
        case "graylog": return ["url", "streamId", "username", "password"]
        case "grafana": return ["url", "authToken"]
        default: return []
        }
    }
    static func label(_ field: String) -> String {
        ["owner":"Repository owner", "repo":"Repository", "workflowId":"Workflow file name or ID", "authToken":"Access token", "orgUrl":"Organization HTTPS URL", "project":"Project", "pipelineId":"Pipeline ID", "workspace":"Workspace", "branch":"Branch", "url":"Server HTTPS URL", "name":"Project name (optional)", "site":"Provider region domain", "monitorId":"Monitor ID", "apiKey":"API key", "appKey":"Application key", "organization":"Organization", "host":"Provider region domain", "identifier":"Alert ID", "streamId":"Stream ID (optional)", "username":"Username", "password":"Password"][field] ?? field
    }
    static func secret(_ field: String) -> Bool { ["authToken", "apiKey", "appKey", "password"].contains(field) }
}
enum DevOpsHealth: String { case healthy = "Healthy", failed = "Needs attention", running = "Running", unknown = "Unavailable" }
struct DevOpsResult {
    var health: DevOpsHealth
    var detail: String
    var link: URL?
    var checked = Date()
}
enum DevOpsError: Error { case invalidConfiguration, invalidResponse, keychain(OSStatus) }

// Redirects are rejected, even to another HTTPS endpoint: credentials must stay at the configured destination.
final class DevOpsHTTP: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func fetch(_ request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw DevOpsError.invalidResponse }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 2_000_000 else { throw DevOpsError.invalidResponse }
            data.append(byte)
        }
        return data
    }
}
final class CCTrayProjects: NSObject, XMLParserDelegate {
    var projects: [[String: String]] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "Project" { projects.append(attributeDict) }
    }
}
enum DevOpsAdapter {
    static func url(_ value: String) -> URL? {
        guard let u = URL(string: value), u.scheme == "https", u.host != nil, u.user == nil, u.password == nil, u.fragment == nil else { return nil }
        return u
    }
    static func request(_ monitor: DevOpsMonitor) throws -> URLRequest {
        let f = monitor.fields
        func get(_ key: String) throws -> String { guard let s = f[key], !s.isEmpty else { throw DevOpsError.invalidConfiguration }; return s }
        func part(_ key: String) throws -> String { try get(key).addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
        func base(_ key: String) throws -> String { guard let u = url(try get(key)), u.query == nil else { throw DevOpsError.invalidConfiguration }; return u.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        func site(_ key: String, allowed: [String]) throws -> String { let s = try get(key).lowercased(); guard allowed.contains(s) else { throw DevOpsError.invalidConfiguration }; return s }
        var endpoint: String
        var headers: [String:String] = ["Accept":"application/json", "User-Agent":"infravibe"]
        func bearer() { if let token = f["authToken"], !token.isEmpty { headers["Authorization"] = "Bearer " + token } }
        switch monitor.type {
        case "githubAction":
            endpoint = "https://api.github.com/repos/\(try part("owner"))/\(try part("repo"))/actions/workflows/\(try part("workflowId"))/runs?per_page=1"
            bearer(); headers["X-GitHub-Api-Version"] = "2022-11-28"
        case "azureDevOps":
            endpoint = "\(try base("orgUrl"))/\(try part("project"))/_apis/pipelines/\(try part("pipelineId"))/runs?api-version=7.1"
            headers["Authorization"] = "Basic " + Data((":" + (try get("authToken"))).utf8).base64EncodedString()
        case "bitbucket":
            endpoint = "https://api.bitbucket.org/2.0/repositories/\(try part("workspace"))/\(try part("repo"))/pipelines?target.ref_name=\(try part("branch"))&sort=-created_on&pagelen=1"; bearer()
        case "ccTray": endpoint = try get("url"); headers["Accept"] = "application/xml"
        case "datadogMonitor":
            endpoint = "https://api.\(try site("site", allowed: ["datadoghq.com","datadoghq.eu","us3.datadoghq.com","us5.datadoghq.com","ap1.datadoghq.com","ap2.datadoghq.com","ddog-gov.com"]))/api/v1/monitor/\(try part("monitorId"))"
            headers["DD-API-KEY"] = try get("apiKey"); headers["DD-APPLICATION-KEY"] = try get("appKey")
        case "sentry": endpoint = "https://sentry.io/api/0/projects/\(try part("organization"))/\(try part("project"))/issues/?query=is%3Aunresolved&limit=1"; bearer()
        case "newRelic": endpoint = "https://api.\(try site("site", allowed: ["newrelic.com","eu.newrelic.com"]))/v2/alerts_violations.json?only_open=true"; headers["X-Api-Key"] = try get("apiKey")
        case "opsgenie": endpoint = "https://api.\(try site("host", allowed: ["opsgenie.com","eu.opsgenie.com"]))/v2/alerts/\(try part("identifier"))?identifierType=id"; headers["Authorization"] = "GenieKey " + (try get("apiKey"))
        case "graylog":
            let stream = (f["streamId"] ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            endpoint = "\(try base("url"))/api/streams\(stream.isEmpty ? "" : "/" + stream)/alerts/paginated?skip=0&limit=5&state=unresolved"
            headers["Authorization"] = "Basic " + Data((try get("username") + ":" + get("password")).utf8).base64EncodedString()
            headers["X-Requested-By"] = "infravibe"
        case "grafana": endpoint = "\(try base("url"))/api/prometheus/grafana/api/v1/rules"; bearer()
        default: throw DevOpsError.invalidConfiguration
        }
        guard let u = url(endpoint) else { throw DevOpsError.invalidConfiguration }
        var request = URLRequest(url: u); request.allHTTPHeaderFields = headers
        return request
    }
    static func parse(_ data: Data, monitor m: DevOpsMonitor) throws -> DevOpsResult {
        var health: DevOpsHealth = .unknown
        var link: String?
        if m.type == "ccTray" {
            // Never resolve DTDs or external entities from a monitoring feed.
            guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw DevOpsError.invalidResponse }
            let delegate = CCTrayProjects(), parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), let p = delegate.projects.first(where: { (m.fields["name"] ?? "").isEmpty || $0["name"] == m.fields["name"] }) else { throw DevOpsError.invalidResponse }
            if ["Building","CheckingModifications"].contains(p["activity"] ?? "") { health = .running }
            else { health = p["lastBuildStatus"] == "Success" ? .healthy : (["Failure","Exception"].contains(p["lastBuildStatus"] ?? "") ? .failed : .unknown) }
            link = p["webUrl"]
        } else {
            let json = try JSONSerialization.jsonObject(with: data)
            let root = json as? [String:Any] ?? [:]
            func first(_ key: String) throws -> [String:Any] { guard let item = (root[key] as? [[String:Any]])?.first else { throw DevOpsError.invalidResponse }; return item }
            switch m.type {
            case "githubAction":
                let run = try first("workflow_runs"); link = run["html_url"] as? String
                if ["queued","in_progress","waiting","pending","requested"].contains(run["status"] as? String ?? "") { health = .running }
                else { health = run["conclusion"] as? String == "success" ? .healthy : (["failure","timed_out","action_required","startup_failure"].contains(run["conclusion"] as? String ?? "") ? .failed : .unknown) }
            case "azureDevOps":
                let run = try first("value"); link = ((run["_links"] as? [String:Any])?["web"] as? [String:Any])?["href"] as? String
                health = run["state"] as? String == "inProgress" ? .running : (run["result"] as? String == "succeeded" ? .healthy : (run["result"] as? String == "failed" ? .failed : .unknown))
            case "bitbucket":
                let run = try first("values"); let state = run["state"] as? [String:Any] ?? [:]; let result = (state["result"] as? [String:Any])?["name"] as? String
                health = ["PENDING","IN_PROGRESS"].contains(state["name"] as? String ?? "") ? .running : (result == "SUCCESSFUL" ? .healthy : (["FAILED","ERROR"].contains(result ?? "") ? .failed : .unknown))
                link = ((run["links"] as? [String:Any])?["html"] as? [String:Any])?["href"] as? String
            case "datadogMonitor":
                let state = root["overall_state"] as? String; health = state == "OK" ? .healthy : (["Alert","Warn"].contains(state ?? "") ? .failed : .unknown)
                link = "https://app.\(m.fields["site"] ?? "")/monitors/\(m.fields["monitorId"] ?? "")"
            case "sentry":
                guard let issues = json as? [[String:Any]] else { throw DevOpsError.invalidResponse }
                health = issues.isEmpty ? .healthy : .failed; link = issues.first?["permalink"] as? String
            case "newRelic":
                guard let items = root["violations"] as? [[String:Any]] else { throw DevOpsError.invalidResponse }
                health = items.isEmpty ? .healthy : .failed; link = "https://one.\(m.fields["site"] ?? "")/nrai"
            case "opsgenie":
                let status = (root["data"] as? [String:Any])?["status"] as? String
                health = status == "open" ? .failed : (status == "closed" ? .healthy : .unknown)
                link = "https://app.\(m.fields["host"] ?? "")/alert/detail/\(m.fields["identifier"] ?? "")/details"
            case "graylog":
                guard let count = root["total"] as? Int, count >= 0 else { throw DevOpsError.invalidResponse }
                health = count > 0 ? .failed : .healthy; link = (m.fields["url"] ?? "") + "/alerts"
            case "grafana":
                guard root["status"] as? String == "success", let groups = (root["data"] as? [String:Any])?["groups"] as? [[String:Any]] else { throw DevOpsError.invalidResponse }
                let rules = groups.flatMap { $0["rules"] as? [[String:Any]] ?? [] }.filter { $0["type"] as? String == "alerting" }
                if rules.isEmpty { health = .unknown }
                else if rules.contains(where: { $0["state"] as? String == "firing" }) { health = .failed }
                else if rules.contains(where: { $0["state"] as? String == "pending" }) { health = .running }
                else if rules.allSatisfy({ $0["state"] as? String == "inactive" && $0["health"] as? String == "ok" }) { health = .healthy }
                link = (m.fields["url"] ?? "") + "/alerting"
            default: throw DevOpsError.invalidConfiguration
            }
        }
        return DevOpsResult(health: health, detail: health.rawValue, link: link.flatMap(url))
    }
    static func imported(_ data: Data) throws -> [DevOpsMonitor] {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], let rows = root["observables"] as? [[String:Any]], rows.count <= 100 else { throw DevOpsError.invalidConfiguration }
        return try rows.map { row in
            guard let type = row["type"] as? String, DevOpsProvider.types.contains(type) else { throw DevOpsError.invalidConfiguration }
            var fields: [String:String] = [:]
            for key in DevOpsProvider.fields(type) + ["alias"] {
                if let value = row[key] as? String { fields[key] = value }
                else if let value = row[key] as? NSNumber { fields[key] = value.stringValue }
            }
            let monitor = DevOpsMonitor(type: type, fields: fields, muted: row["muted"] as? Bool ?? false)
            _ = try request(monitor)
            return monitor
        }
    }
}

final class DevOpsModel: ObservableObject {
    @Published private(set) var monitors: [DevOpsMonitor] = []
    @Published private(set) var results: [UUID:DevOpsResult] = [:]
    @Published private(set) var refreshing = false
    @Published var message = ""
    private var loaded = false
    private var timer: Timer?
    private var generation = 0
    private let keychain: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.dynadobe.infraproxy.devops", kSecAttrAccount as String:"monitors"]
    var summary: String {
        if !loaded { return "Unlock / set up" }
        if monitors.isEmpty { return "No monitors" }
        let failures = results.values.filter { $0.health == .failed }.count
        let unknown = monitors.filter { results[$0.id] == nil || results[$0.id]?.health == .unknown || (results[$0.id].map { Date().timeIntervalSince($0.checked) > 120 } ?? false) }.count
        if failures > 0 { return "\(failures) need attention" }
        if unknown > 0 { return "\(unknown) unavailable" }
        return results.values.contains { $0.health == .running } ? "Builds running" : "All healthy"
    }
    func load() {
        guard !loaded else { return }
        var query = keychain; query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else { message = "Could not unlock DevOps credentials in Keychain."; return }
        if let data = value as? Data {
            guard let saved = try? JSONDecoder().decode([DevOpsMonitor].self, from: data) else { message = "Saved DevOps configuration could not be read."; return }
            monitors = saved
        }
        loaded = true; refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }
    deinit { timer?.invalidate() }
    func save(_ items: [DevOpsMonitor]) throws {
        guard loaded, items.count <= 100 else { throw DevOpsError.invalidConfiguration }
        for item in items { _ = try DevOpsAdapter.request(item) }
        let data = try JSONEncoder().encode(items)
        var status = SecItemUpdate(keychain as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = keychain; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DevOpsError.keychain(status) }
        UserDefaults.standard.set(!items.isEmpty, forKey: "devOpsConfigured")
        generation += 1; monitors = items; results = [:]; refreshing = false; refresh()
    }
    func refresh() {
        guard loaded, !refreshing, !monitors.isEmpty else { return }
        refreshing = true
        let batch = monitors, version = generation
        Task { @MainActor in
            await withTaskGroup(of: (UUID, DevOpsResult).self) { group in
                var iterator = batch.makeIterator()
                func enqueue(_ monitor: DevOpsMonitor) {
                    group.addTask {
                        do { return (monitor.id, try DevOpsAdapter.parse(await DevOpsHTTP().fetch(DevOpsAdapter.request(monitor)), monitor: monitor)) }
                        catch { return (monitor.id, DevOpsResult(health: .unknown, detail: "Unable to read status. Check endpoint, credentials, and connectivity.", link: nil)) }
                    }
                }
                for _ in 0..<4 { if let monitor = iterator.next() { enqueue(monitor) } }
                for await (id, result) in group {
                    guard version == generation else { group.cancelAll(); return }
                    let old = results[id]?.health
                    results[id] = result
                    if let monitor = batch.first(where: { $0.id == id }), !monitor.muted,
                       UserDefaults.standard.bool(forKey: "devOpsNotifications"), let old, old != result.health,
                       result.health == .failed || (old == .failed && result.health == .healthy) {
                        let content = UNMutableNotificationContent()
                        content.title = "infravibe · DevOps"
                        content.body = "A monitor changed to " + result.health.rawValue.lowercased() + ". Open DevOps for details."
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "devops-" + id.uuidString, content: content, trigger: nil))
                    }
                    if let monitor = iterator.next() { enqueue(monitor) }
                }
            }
            if version == generation { self.refreshing = false }
        }
    }
}

struct DevOpsView: View {
    @ObservedObject var model: DevOpsModel
    @AppStorage("devOpsNotifications") private var notifications = false
    @State private var type = "githubAction"
    @State private var fields: [String:String] = [:]
    @State private var pending: [DevOpsMonitor] = []
    @State private var editing: UUID?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection("DevOps · Barklarm") {
                    HStack { Text(model.summary).font(.headline); Spacer(); Button("Refresh") { model.load(); model.refresh() }.disabled(model.refreshing) }
                    Text("Builds, issues and monitoring alerts, adapted from Barklarm. Checks every 60 seconds while this app is running. Credentials stay in this Mac’s Keychain. HTTPS is required.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Notify when a monitor fails or recovers", isOn: $notifications).onChange(of: notifications) { _, enabled in
                        if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
                    }
                    Text("Notifications need macOS permission. Muted monitors imported from Barklarm remain silent.").font(.caption).foregroundStyle(.secondary)
                    Button("Import Barklarm configuration…", action: importFile)
                    if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary) }
                }
                if !pending.isEmpty {
                    SettingsSection("Review import") {
                        Text("\(pending.count) monitors. Saving enables requests to these providers; imported credentials are stored in Keychain.")
                        ForEach(pending) { item in
                            Text("\(item.name) · \(DevOpsProvider.title(item.type)) · \((try? DevOpsAdapter.request(item).url?.host) ?? "")")
                        }
                        HStack {
                            Button("Import and start monitoring") { if save(model.monitors + pending) { pending = [] } }
                            Button("Cancel") { pending = [] }
                        }
                    }
                }
                ForEach(model.monitors) { monitor in
                    SettingsSection(monitor.name) {
                        let result = model.results[monitor.id]
                        HStack {
                            Circle().fill(color(result?.health)).frame(width: 8, height: 8)
                            Text(result?.detail ?? "Checking…"); Spacer()
                            if let link = result?.link { Link("Open", destination: link) }
                            Button("Edit") { type = monitor.type; fields = monitor.fields; editing = monitor.id }
                            Button("Remove") { save(model.monitors.filter { $0.id != monitor.id }) }
                        }
                        if let checked = result?.checked { Text("Checked \(checked.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                SettingsSection(editing == nil ? "Add monitor" : "Edit monitor") {
                    Picker("Provider", selection: $type) { ForEach(DevOpsProvider.types, id: \.self) { Text(DevOpsProvider.title($0)).tag($0) } }.disabled(editing != nil).onChange(of: type) { _, _ in if editing == nil { fields = [:] } }
                    TextField("Display name", text: binding("alias"))
                    ForEach(DevOpsProvider.fields(type), id: \.self) { field in
                        if DevOpsProvider.secret(field) { SecureField(DevOpsProvider.label(field), text: binding(field)) }
                        else { TextField(DevOpsProvider.label(field), text: binding(field)) }
                    }
                    Text("Use read-only credentials. For CCTray, name is optional. GitHub authToken is optional for public repositories. Review custom server addresses before saving.").font(.caption).foregroundStyle(.secondary)
                    Button("Save and start monitoring") {
                        let item = DevOpsMonitor(id: editing ?? UUID(), type: type, fields: fields.filter { (DevOpsProvider.fields(type) + ["alias"]).contains($0.key) }, muted: model.monitors.first { $0.id == editing }?.muted ?? false)
                        if save(model.monitors.filter { $0.id != editing } + [item]) { fields = [:]; editing = nil }
                    }
                    if editing != nil { Button("Cancel edit") { editing = nil; fields = [:] } }
                }
            }.padding(28)
        }.onAppear(perform: model.load)
    }
    private func color(_ health: DevOpsHealth?) -> Color { health == .healthy ? .green : (health == .failed ? .red : (health == .running ? .orange : .secondary)) }
    private func binding(_ key: String) -> Binding<String> { Binding(get: { fields[key] ?? "" }, set: { fields[key] = $0 }) }
    @discardableResult private func save(_ monitors: [DevOpsMonitor]) -> Bool {
        do { try model.save(monitors); model.message = "Saved in Keychain."; return true }
        catch { model.message = "Could not save. Check required fields, HTTPS addresses, supported provider region, and Keychain access."; return false }
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a Barklarm JSON export. Review the monitors before importing."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 1_000_000 else { throw DevOpsError.invalidConfiguration }
            pending = try DevOpsAdapter.imported(Data(contentsOf: url))
            model.message = pending.isEmpty ? "No monitors found in this export." : "Review the import below."
        } catch { model.message = "Could not import. Expected Barklarm observables with supported providers and HTTPS endpoints. Nothing was imported." }
    }
}
struct DevOpsMenuSummary: View {
    @ObservedObject var model: DevOpsModel
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack { Label("DevOps", systemImage: "hammer"); Spacer(); Text(model.summary).foregroundStyle(.secondary) }
                .font(.system(size: 12, weight: .medium))
        }.buttonStyle(.plain)
    }
}
