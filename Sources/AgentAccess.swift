import Cocoa
import SwiftUI
import CryptoKit

struct AgentGrant: Codable, Identifiable {
    let id: String, name: String, digest: String
    var expires: Date
    var terminalUntil: Date?
    var requestedControl = false
    var canControl: Bool { expires > Date() && (terminalUntil ?? .distantPast) > Date() }
}
struct AgentEvent: Codable, Identifiable {
    let id: String, date: Date, agent: String, action: String, outcome: String
}
// Only token hashes persist. Permission checks always re-read this store.
final class AgentAccess: ObservableObject {
    private let lock = NSLock()
    private let file: URL?
    private var grants: [AgentGrant] = []
    private var events: [AgentEvent] = []
    var onRevoke: ((String) -> Void)?
    init(file: URL? = nil) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) { grants = saved.grants; events = saved.events }
    }
    private struct Saved: Codable { let grants: [AgentGrant]; let events: [AgentEvent] }
    var all: [AgentGrant] { lock.lock(); defer { lock.unlock() }; return grants }
    var activity: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
    private static func digest(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func saveLocked() {
        if let file, let data = try? JSONEncoder().encode(Saved(grants: grants, events: events)) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
    func create(name: String, hours: Double = 24) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.contains(where: \.isNewline), [1.0, 24.0, 168.0].contains(hours) else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard grants.count < 32 else { return nil }
        let token = "ip_agent_" + BrowserSecurity.token()
        grants.append(AgentGrant(id: UUID().uuidString, name: name, digest: Self.digest(token), expires: Date().addingTimeInterval(hours * 3600)))
        saveLocked(); return token
    }
    func authenticate(_ token: String) -> AgentGrant? {
        guard token.hasPrefix("ip_agent_"), token.count == 73 else { return nil }
        let digest = Self.digest(token)
        lock.lock(); defer { lock.unlock() }
        return grants.first { BrowserSecurity.equal($0.digest, digest) && $0.expires > Date() }
    }
    func grant(_ id: String) -> AgentGrant? { all.first { $0.id == id && $0.expires > Date() } }
    func requestControl(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = grants.firstIndex(where: { $0.id == id }) else { return }
        grants[index].requestedControl = true; saveLocked()
    }
    func approveControl(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let index = grants.firstIndex(where: { $0.id == id }) else { return }
        grants[index].terminalUntil = min(grants[index].expires, Date().addingTimeInterval(3600)); grants[index].requestedControl = false; saveLocked()
    }
    func revoke(_ id: String) {
        lock.lock(); grants.removeAll { $0.id == id }; saveLocked(); lock.unlock()
        onRevoke?(id)
    }
    func record(_ grant: AgentGrant, _ action: String, _ outcome: String) {
        lock.lock(); defer { lock.unlock() }
        events.insert(AgentEvent(id: UUID().uuidString, date: Date(), agent: grant.name, action: action, outcome: outcome), at: 0)
        if events.count > 200 { events.removeLast(events.count - 200) }; saveLocked()
    }
}

