import Foundation
import CryptoKit
import CommonCrypto
import Security

struct DevOpsPreferences: Codable, Equatable {
    var refreshSeconds = 60
    var automaticRefresh = true
    var issueEndpoint = ""
    var notifications = false
    var sound = false
    var notifyRecovery = true
    var notifyAllChanges = false
    func validated() throws -> Self {
        guard (60...3600).contains(refreshSeconds), issueEndpoint.isEmpty || DevOpsAdapter.url(issueEndpoint) != nil else { throw DevOpsError.invalidConfiguration }
        return self
    }
}
struct DevOpsConfiguration: Codable {
    var version = 1
    var monitors: [DevOpsMonitor]
    var preferences = DevOpsPreferences()
    func validated(requireCredentials: Bool = true) throws -> Self {
        guard version == 1, monitors.reduce(0, { $0 + $1.fields.values.reduce(0, { $0 + $1.utf8.count }) }) <= 800_000, monitors.count <= 100, Set(monitors.map(\.id)).count == monitors.count else { throw DevOpsError.invalidConfiguration }
        _ = try preferences.validated()
        for monitor in monitors {
            guard DevOpsProvider.types.contains(monitor.type), monitor.fields.values.allSatisfy({ $0.utf8.count <= 8192 }), monitor.group.count <= 120,
                  (monitor.fields["issueEndpoint"] ?? "").isEmpty || DevOpsAdapter.url(monitor.fields["issueEndpoint"]!) != nil else { throw DevOpsError.invalidConfiguration }
            if requireCredentials && monitor.enabled { _ = try DevOpsAdapter.request(monitor) }
        }
        return self
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 2_000_000 else { throw DevOpsError.invalidConfiguration }
        let decoder = JSONDecoder()
        if let config = try? decoder.decode(Self.self, from: data) { return try config.validated(requireCredentials: false) }
        // 2.9 saved only an array. Keep monitor IDs and credentials when upgrading.
        if let legacy = try? decoder.decode([DevOpsMonitor].self, from: data) {
            return try Self(monitors: legacy).validated(requireCredentials: false)
        }
        let monitors = try DevOpsAdapter.imported(data)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        var preferences = DevOpsPreferences()
        if let interval = raw["refreshInterval"] as? Int { preferences.refreshSeconds = max(60, min(3600, interval / 1000)) }
        preferences.issueEndpoint = raw["issueGlobalEndpoint"] as? String ?? ""
        return try Self(monitors: monitors, preferences: preferences).validated()
    }
    func template() -> Self {
        var copy = self
        copy.preferences.issueEndpoint = Self.publicURL(copy.preferences.issueEndpoint)
        copy.monitors = monitors.map { monitor in
            var item = monitor
            item.enabled = false
            item.fields = item.fields.filter { !DevOpsProvider.secret($0.key) }
            for key in ["url", "orgUrl", "issueEndpoint"] {
                if let value = item.fields[key] { item.fields[key] = Self.publicURL(value) }
            }
            return item
        }
        return copy
    }
    static func publicURL(_ value: String) -> String {
        guard var components = URLComponents(string: value), components.scheme == "https", components.host != nil else { return "" }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        return components.string ?? ""
    }
}

// Password-protected local backup, never plaintext credentials. Random salt + AES-GCM nonce per export.
enum DevOpsBackup {
    struct Envelope: Codable { let format: String; let version: Int; let rounds: Int; let salt: Data; let sealed: Data }
    private static let rounds: UInt32 = 600_000
    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        guard password.utf8.count >= 12, password.utf8.count <= 1024, salt.count == 16 else { throw DevOpsError.invalidConfiguration }
        let bytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBytes in
            bytes.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.bindMemory(to: Int8.self).baseAddress, bytes.count,
                                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw DevOpsError.invalidConfiguration }
        return SymmetricKey(data: derived)
    }
    static func seal(_ configuration: DevOpsConfiguration, password: String) throws -> Data {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let plaintext = try JSONEncoder().encode(configuration)
        let sealed = try AES.GCM.seal(plaintext, using: key(password, salt: salt), authenticating: Data("infravibe-devops-v1".utf8))
        return try JSONEncoder().encode(Envelope(format: "infravibe-devops", version: 1, rounds: Int(rounds), salt: salt, sealed: sealed.combined!))
    }
    static func open(_ data: Data, password: String) throws -> DevOpsConfiguration {
        guard data.count <= 3_000_000 else { throw DevOpsError.invalidConfiguration }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.format == "infravibe-devops", envelope.version == 1, envelope.rounds == Int(rounds) else { throw DevOpsError.invalidConfiguration }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.sealed), using: key(password, salt: envelope.salt), authenticating: Data("infravibe-devops-v1".utf8))
        return try DevOpsConfiguration.decode(bytes)
    }
    static func encrypted(_ data: Data) -> Bool { (try? JSONDecoder().decode(Envelope.self, from: data)) != nil }
}

enum DevOpsSetup {
    static func fromLink(_ text: String) throws -> DevOpsMonitor {
        guard let url = DevOpsAdapter.url(text.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host?.lowercased() else { throw DevOpsError.invalidConfiguration }
        let p = url.pathComponents.filter { $0 != "/" }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func monitor(_ type: String, _ fields: [String:String]) -> DevOpsMonitor { DevOpsMonitor(type: type, fields: fields) }
        if host == "github.com", p.count == 5, p[2] == "actions", p[3] == "workflows" { return monitor("githubAction", ["owner":p[0], "repo":p[1], "workflowId":p[4]]) }
        if host.hasPrefix("app."), p.count == 2, p[0] == "monitors" {
            let site = String(host.dropFirst(4))
            if ["datadoghq.com","datadoghq.eu","us3.datadoghq.com","us5.datadoghq.com","ap1.datadoghq.com","ap2.datadoghq.com","ddog-gov.com"].contains(site) { return monitor("datadogMonitor", ["site":site, "monitorId":p[1]]) }
        }
        if host == "sentry.io", p.count >= 4, p[0] == "organizations", p[2] == "projects" { return monitor("sentry", ["organization":p[1], "project":p[3]]) }
        if host == "dev.azure.com", p.count == 3, p[2] == "_build", let id = query.first(where: { $0.name == "definitionId" })?.value { return monitor("azureDevOps", ["orgUrl":"https://dev.azure.com/" + p[0], "project":p[1], "pipelineId":id]) }
        if host.hasSuffix(".visualstudio.com"), p.count == 2, p[1] == "_build", let id = query.first(where: { $0.name == "definitionId" })?.value { return monitor("azureDevOps", ["orgUrl":"https://" + host, "project":p[0], "pipelineId":id]) }
        if ["app.opsgenie.com","app.eu.opsgenie.com"].contains(host), p.count == 4, p[0] == "alert", p[1] == "detail", p[3] == "details" { return monitor("opsgenie", ["host":String(host.dropFirst(4)), "identifier":p[2]]) }
        if ["cc.xml","cctray.xml"].contains(url.lastPathComponent.lowercased()) { return monitor("ccTray", ["url":url.absoluteString]) }
        if let index = p.firstIndex(of: "alerts") {
            var base = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            base.path = "/" + p.prefix(index).joined(separator: "/"); base.query = nil
            return monitor("graylog", ["url":base.string!])
        }
        throw DevOpsError.invalidConfiguration
    }
    static func defaults(_ type: String) -> [String:String] {
        switch type { case "datadogMonitor": return ["site":"datadoghq.com"]; case "newRelic": return ["site":"newrelic.com"]; case "opsgenie": return ["host":"opsgenie.com"]; case "bitbucket": return ["branch":"main"]; default: return [:] }
    }
    static func help(_ type: String) -> String {
        switch type {
        case "githubAction": return "Use a fine-grained token with read access to Actions on the selected repository. Public workflows can be read without a token. Paste a workflow page link to fill the repository and workflow."
        case "azureDevOps": return "Use an Azure DevOps personal access token with Build read access. The organization URL must point to the service you trust."
        case "bitbucket": return "Use a bearer access token with permission to read this repository’s pipelines."
        case "ccTray": return "Use your CI server’s HTTPS CCTray feed. Test it to discover project names. Credentials embedded in URLs are not accepted."
        case "datadogMonitor": return "Use your Datadog site domain, API key and application key with monitor read access."
        case "sentry": return "Use a Sentry token that can read the selected project’s unresolved issues."
        case "newRelic": return "Use a New Relic user API key for the selected region. This adapter uses the open violations API."
        case "opsgenie": return "Use a read-enabled Opsgenie integration API key and an existing alert ID."
        case "graylog": return "Use a read-only Graylog account and the HTTPS server base URL. Stream ID is optional."
        case "grafana": return "Use a Grafana service account token with permission to read alert rules. Enter the HTTPS Grafana base URL."
        default: return ""
        }
    }
}

struct DevOpsIssue: Identifiable {
    let id = UUID()
    let endpoint: URL
    let body: Data
    static func prepare(monitor: DevOpsMonitor, result: DevOpsResult, preferences: DevOpsPreferences) throws -> Self {
        let override = monitor.fields["issueEndpoint"] ?? ""
        guard result.health == .failed, Date().timeIntervalSince(result.checked) <= Double(preferences.refreshSeconds + 60),
              let endpoint = DevOpsAdapter.url(override.isEmpty ? preferences.issueEndpoint : override) else { throw DevOpsError.invalidConfiguration }
        let payload: [String:Any] = ["name":monitor.name, "status":1, "statusLabel":"FAILURE", "link":DevOpsConfiguration.publicURL(result.link?.absoluteString ?? ""),
                                   "muted":monitor.muted, "error":["id":result.eventID ?? monitor.id.uuidString, "description":result.detail]]
        return Self(endpoint: endpoint, body: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }
    var request: URLRequest {
        var value = URLRequest(url: endpoint); value.httpMethod = "POST"; value.httpBody = body
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return value
    }
}

struct DevOpsChoice: Identifiable { let id: String; let title: String }
enum DevOpsDiscovery {
    static func field(_ type: String) -> String? {
        ["githubAction":"workflowId", "azureDevOps":"pipelineId", "ccTray":"name", "datadogMonitor":"monitorId", "sentry":"project", "opsgenie":"identifier", "graylog":"streamId", "bitbucket":"branch"][type]
    }
    static func request(_ monitor: DevOpsMonitor) throws -> URLRequest {
        guard let field = field(monitor.type) else { throw DevOpsError.invalidConfiguration }
        var draft = monitor
        if (draft.fields[field] ?? "").isEmpty { draft.fields[field] = "discovery" }
        var request = try DevOpsAdapter.request(draft)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        switch monitor.type {
        case "githubAction": components.percentEncodedPath = components.percentEncodedPath.components(separatedBy: "/actions/workflows/")[0] + "/actions/workflows"; components.query = "per_page=100"
        case "azureDevOps": components.percentEncodedPath = components.percentEncodedPath.components(separatedBy: "/_apis/pipelines/")[0] + "/_apis/pipelines"; components.query = "api-version=7.1"
        case "datadogMonitor": components.path = "/api/v1/monitor"; components.query = "page=0&page_size=100"
        case "sentry": components.percentEncodedPath = "/api/0/organizations/" + (draft.fields["organization"] ?? "").addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "/projects/"; components.query = nil
        case "opsgenie": components.path = "/v2/alerts"; components.query = "limit=100&query=status%3Aopen"
        case "graylog": components.percentEncodedPath = components.percentEncodedPath.components(separatedBy: "/api/streams")[0] + "/api/streams"; components.query = nil
        case "bitbucket": components.percentEncodedPath = components.percentEncodedPath.components(separatedBy: "/pipelines")[0] + "/refs/branches"; components.query = "pagelen=100"
        case "ccTray": break
        default: throw DevOpsError.invalidConfiguration
        }
        request.url = components.url
        return request
    }
    static func choices(_ data: Data, type: String) throws -> [DevOpsChoice] {
        if type == "ccTray" {
            guard let xml = String(data: data, encoding: .utf8), !xml.uppercased().contains("<!DOCTYPE"), !xml.uppercased().contains("<!ENTITY") else { throw DevOpsError.invalidResponse }
            let delegate = CCTrayProjects(), parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { throw DevOpsError.invalidResponse }
            var seen: Set<String> = []
            return delegate.projects.compactMap { p in p["name"].map { DevOpsChoice(id: $0, title: $0) } }.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        }
        let value = try JSONSerialization.jsonObject(with: data)
        let root = value as? [String:Any] ?? [:]
        let key = ["githubAction":"workflows", "azureDevOps":"value", "opsgenie":"data", "graylog":"streams", "bitbucket":"values"][type]
        guard let rows = key.flatMap({ root[$0] as? [[String:Any]] }) ?? value as? [[String:Any]] else { throw DevOpsError.invalidResponse }
        let items = rows.compactMap { row -> DevOpsChoice? in
            let idValue = type == "sentry" ? row["slug"] : (type == "bitbucket" ? row["name"] : row["id"])
            let id = (idValue as? String) ?? (idValue as? NSNumber)?.stringValue
            guard let id else { return nil }
            let title = (row["name"] ?? row["title"] ?? row["message"]) as? String ?? id
            return DevOpsChoice(id: id, title: title)
        }
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }
}


enum DevOpsNotificationPolicy {
    static func shouldNotify(previous: DevOpsHealth?, current: DevOpsHealth, monitor: DevOpsMonitor, preferences: DevOpsPreferences) -> Bool {
        guard preferences.notifications, monitor.enabled, !monitor.muted, previous != current else { return false }
        if preferences.notifyAllChanges { return previous != nil || current != .unknown }
        return current == .failed || (preferences.notifyRecovery && previous == .failed && current == .healthy)
    }
}


protocol DevOpsStoring {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
struct DevOpsKeychainStore: DevOpsStoring {
    private let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"com.dynadobe.infraproxy.devops", kSecAttrAccount as String:"monitors"]
    func read() throws -> Data? {
        var attributes = query; attributes[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DevOpsError.keychain(status) }
        return data
    }
    func write(_ data: Data) throws {
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query; attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DevOpsError.keychain(status) }
    }
}
