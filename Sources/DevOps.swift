// Native adaptation of Barklarm observers. See Vendor/BARKLARM.md and third-party notices.
import Cocoa
import SwiftUI
import Security
import UserNotifications

struct DevOpsMonitor: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: String
    var fields: [String: String]
    var muted = false
    var group = ""
    var enabled = true
    var name: String { fields["alias"].flatMap { $0.isEmpty ? nil : $0 } ?? DevOpsProvider.title(type) }
    init(id: UUID = UUID(), type: String, fields: [String:String], muted: Bool = false, group: String = "", enabled: Bool = true) {
        self.id = id; self.type = type; self.fields = fields; self.muted = muted; self.group = group; self.enabled = enabled
    }
    enum CodingKeys: String, CodingKey { case id, type, fields, muted, group, enabled }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); type = try c.decode(String.self, forKey: .type)
        fields = try c.decode([String:String].self, forKey: .fields)
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        group = try c.decodeIfPresent(String.self, forKey: .group) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
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
    var eventID: String? = nil
}
enum DevOpsError: Error { case invalidConfiguration, invalidResponse, keychain(OSStatus) }

// Redirects are rejected, even to another HTTPS endpoint: credentials must stay at the configured destination.
final class DevOpsHTTP: NSObject, URLSessionTaskDelegate {
    private let protocolClasses: [AnyClass]?
    init(protocolClasses: [AnyClass]? = nil) { self.protocolClasses = protocolClasses; super.init() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func fetch(_ request: URLRequest, acceptedStatus: Range<Int> = 200..<201) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = protocolClasses
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, acceptedStatus.contains(response.statusCode) else { throw DevOpsError.invalidResponse }
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
        var eventID: String?
        if m.type == "ccTray" {
            // Never resolve DTDs or external entities from a monitoring feed.
            guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw DevOpsError.invalidResponse }
            let delegate = CCTrayProjects(), parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse(), let p = delegate.projects.first(where: { (m.fields["name"] ?? "").isEmpty || $0["name"] == m.fields["name"] }) else { throw DevOpsError.invalidResponse }
            if ["Building","CheckingModifications"].contains(p["activity"] ?? "") { health = .running }
            else { health = p["lastBuildStatus"] == "Success" ? .healthy : (["Failure","Exception"].contains(p["lastBuildStatus"] ?? "") ? .failed : .unknown) }
            eventID = (p["name"] ?? "") + "_" + (p["lastBuildTime"] ?? "")
            link = p["webUrl"]
        } else {
            let json = try JSONSerialization.jsonObject(with: data)
            let root = json as? [String:Any] ?? [:]
            func first(_ key: String) throws -> [String:Any] { guard let item = (root[key] as? [[String:Any]])?.first else { throw DevOpsError.invalidResponse }; return item }
            switch m.type {
            case "githubAction":
                let run = try first("workflow_runs"); eventID = (run["id"] as? NSNumber)?.stringValue; link = run["html_url"] as? String
                if ["queued","in_progress","waiting","pending","requested"].contains(run["status"] as? String ?? "") { health = .running }
                else { health = run["conclusion"] as? String == "success" ? .healthy : (["failure","timed_out","action_required","startup_failure"].contains(run["conclusion"] as? String ?? "") ? .failed : .unknown) }
            case "azureDevOps":
                let run = try first("value"); eventID = (run["id"] as? NSNumber)?.stringValue; link = ((run["_links"] as? [String:Any])?["web"] as? [String:Any])?["href"] as? String
                health = run["state"] as? String == "inProgress" ? .running : (run["result"] as? String == "succeeded" ? .healthy : (run["result"] as? String == "failed" ? .failed : .unknown))
            case "bitbucket":
                let run = try first("values"); eventID = run["uuid"] as? String; let state = run["state"] as? [String:Any] ?? [:]; let result = (state["result"] as? [String:Any])?["name"] as? String
                health = ["PENDING","IN_PROGRESS"].contains(state["name"] as? String ?? "") ? .running : (result == "SUCCESSFUL" ? .healthy : (["FAILED","ERROR"].contains(result ?? "") ? .failed : .unknown))
                link = ((run["links"] as? [String:Any])?["html"] as? [String:Any])?["href"] as? String
            case "datadogMonitor":
                eventID = (root["id"] as? NSNumber)?.stringValue
                let state = root["overall_state"] as? String; health = state == "OK" ? .healthy : (["Alert","Warn"].contains(state ?? "") ? .failed : .unknown)
                link = "https://app.\(m.fields["site"] ?? "")/monitors/\(m.fields["monitorId"] ?? "")"
            case "sentry":
                guard let issues = json as? [[String:Any]] else { throw DevOpsError.invalidResponse }
                eventID = issues.first?["id"] as? String
                health = issues.isEmpty ? .healthy : .failed; link = issues.first?["permalink"] as? String
            case "newRelic":
                guard let items = root["violations"] as? [[String:Any]] else { throw DevOpsError.invalidResponse }
                eventID = (items.first?["id"] as? NSNumber)?.stringValue
                health = items.isEmpty ? .healthy : .failed; link = "https://one.\(m.fields["site"] ?? "")/nrai"
            case "opsgenie":
                eventID = (root["data"] as? [String:Any])?["id"] as? String
                let status = (root["data"] as? [String:Any])?["status"] as? String
                health = status == "open" ? .failed : (status == "closed" ? .healthy : .unknown)
                link = "https://app.\(m.fields["host"] ?? "")/alert/detail/\(m.fields["identifier"] ?? "")/details"
            case "graylog":
                guard let count = root["total"] as? Int, count >= 0 else { throw DevOpsError.invalidResponse }
                eventID = (root["alerts"] as? [[String:Any]])?.first?["id"] as? String
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
        return DevOpsResult(health: health, detail: health.rawValue, link: link.flatMap(url), eventID: eventID)
    }
    static func imported(_ data: Data) throws -> [DevOpsMonitor] {
        guard data.count <= 1_000_000, let root = try JSONSerialization.jsonObject(with: data) as? [String:Any], let rows = root["observables"] as? [[String:Any]], rows.count <= 100 else { throw DevOpsError.invalidConfiguration }
        return try rows.map { row in
            guard let type = row["type"] as? String, DevOpsProvider.types.contains(type) else { throw DevOpsError.invalidConfiguration }
            var fields: [String:String] = [:]
            for key in DevOpsProvider.fields(type) + ["alias", "issueEndpoint"] {
                if let value = row[key] as? String { fields[key] = value }
                else if let value = row[key] as? NSNumber { fields[key] = value.stringValue }
            }
            let monitor = DevOpsMonitor(type: type, fields: fields, muted: row["muted"] as? Bool ?? false, group: row["group"] as? String ?? "", enabled: row["enabled"] as? Bool ?? true)
            if monitor.enabled { _ = try request(monitor) }
            return monitor
        }
    }
}

final class DevOpsModel: ObservableObject {
    @Published private(set) var monitors: [DevOpsMonitor] = []
    @Published private(set) var preferences = DevOpsPreferences()
    @Published private(set) var results: [UUID:DevOpsResult] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var loaded = false
    @Published var message = ""
    private var timer: Timer?
    private var generation = 0
    private let store: DevOpsStoring
    private let defaults: UserDefaults
    private let timersEnabled: Bool
    private let checkMonitor: (DevOpsMonitor) async -> DevOpsResult
    init(store: DevOpsStoring = DevOpsKeychainStore(), defaults: UserDefaults = .standard, timersEnabled: Bool = true, check: @escaping (DevOpsMonitor) async -> DevOpsResult = DevOpsModel.check) {
        self.store = store; self.defaults = defaults; self.timersEnabled = timersEnabled; self.checkMonitor = check
    }
    var configuration: DevOpsConfiguration { DevOpsConfiguration(monitors: monitors, preferences: preferences) }
    var summary: String {
        if !loaded { return "Unlock / set up" }
        if monitors.isEmpty { return "No monitors" }
        let active = monitors.filter(\.enabled)
        if active.isEmpty { return "All monitors paused" }
        if !preferences.automaticRefresh { return "Automatic checks paused" }
        let failures = active.filter { results[$0.id]?.health == .failed && !stale($0.id) }.count
        let unknown = active.filter { results[$0.id] == nil || results[$0.id]?.health == .unknown || stale($0.id) }.count
        if failures > 0 { return "\(failures) need attention" }
        if unknown > 0 { return "\(unknown) unavailable" }
        return active.contains { results[$0.id]?.health == .running } ? "Builds running" : "All healthy"
    }
    func stale(_ id: UUID) -> Bool { results[id].map { Date().timeIntervalSince($0.checked) > Double(preferences.refreshSeconds + 60) } ?? true }
    func load() {
        guard !loaded else { return }
        do {
            if let data = try store.read() {
                var saved = try DevOpsConfiguration.decode(data)
                if (try? JSONSerialization.jsonObject(with: data)) is [Any] { saved.preferences.notifications = defaults.bool(forKey: "devOpsNotifications") }
                monitors = saved.monitors; preferences = saved.preferences
            }
        } catch { message = "Could not unlock or read the saved DevOps configuration. Nothing was overwritten. Use Unlock to try again."; return }
        loaded = true; schedule()
        if preferences.automaticRefresh { refresh() }
    }
    deinit { timer?.invalidate() }
    private func schedule() {
        timer?.invalidate(); timer = nil
        if timersEnabled && preferences.automaticRefresh {
            let timer = Timer(timeInterval: Double(preferences.refreshSeconds), repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    func save(_ items: [DevOpsMonitor]) throws { try save(DevOpsConfiguration(monitors: items, preferences: preferences)) }
    func save(_ configuration: DevOpsConfiguration) throws {
        guard loaded else { throw DevOpsError.invalidConfiguration }
        let config = try configuration.validated()
        let data = try JSONEncoder().encode(config)
        try store.write(data)
        defaults.set(!config.monitors.isEmpty, forKey: "devOpsConfigured")
        let old = monitors
        generation += 1; monitors = config.monitors; preferences = config.preferences
        results = results.filter { id, _ in old.first { $0.id == id } == monitors.first { $0.id == id } }
        refreshing = false; schedule()
        if preferences.automaticRefresh { refresh() }
    }
    func refresh() {
        guard loaded, !refreshing else { return }
        let batch = monitors.filter(\.enabled), version = generation
        guard !batch.isEmpty else { return }
        refreshing = true
        Task { @MainActor in
            await withTaskGroup(of: (UUID, DevOpsResult).self) { group in
                var iterator = batch.makeIterator()
                func enqueue(_ monitor: DevOpsMonitor) {
                    group.addTask { (monitor.id, await self.checkMonitor(monitor)) }
                }
                for _ in 0..<4 { if let monitor = iterator.next() { enqueue(monitor) } }
                for await (id, result) in group {
                    guard version == generation else { group.cancelAll(); return }
                    let old = results[id]?.health
                    results[id] = result
                    if let monitor = batch.first(where: { $0.id == id }), DevOpsNotificationPolicy.shouldNotify(previous: old, current: result.health, monitor: monitor, preferences: preferences) {
                        let content = UNMutableNotificationContent()
                        content.title = "infravibe · DevOps"
                        content.body = "A monitor changed to " + result.health.rawValue.lowercased() + ". Open DevOps for details."
                        if preferences.sound { content.sound = .default }
                        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "devops-" + id.uuidString, content: content, trigger: nil))
                    }
                    guard version == generation else { group.cancelAll(); return }
                    if let monitor = iterator.next() { enqueue(monitor) }
                }
            }
            if version == generation { self.refreshing = false }
        }
    }
    static func check(_ monitor: DevOpsMonitor) async -> DevOpsResult {
        do { return try DevOpsAdapter.parse(await DevOpsHTTP().fetch(DevOpsAdapter.request(monitor)), monitor: monitor) }
        catch { return DevOpsResult(health: .unknown, detail: "Unable to read status. Check endpoint, credentials, and connectivity.", link: nil) }
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
