import Cocoa
import SwiftUI
import CryptoKit

struct BrowserKey: Codable, Identifiable {
    let id: String, label: String, raw: Data
}
final class BrowserKeys: ObservableObject {
    private let lock = NSLock()
    private let file: URL?
    let authorizedFile: URL?
    private var keys: [BrowserKey] = []
    private var previousAuthorized: Set<String>?
    func refreshAuthorization() {
        guard authorizedFile != nil else { return }
        let current = Set(all.map(\.id))
        if let previousAuthorized, previousAuthorized != current { onRevoke?() }
        previousAuthorized = current
    }
    var onRevoke: (() -> Void)?
    init(file: URL? = nil, authorizedFile: URL? = nil) {
        self.file = file; self.authorizedFile = authorizedFile
        if let file, let data = try? Data(contentsOf: file), let keys = try? JSONDecoder().decode([BrowserKey].self, from: data) { self.keys = keys }
    }
    var all: [BrowserKey] {
        if let authorizedFile {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: authorizedFile.path),
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 1048576,
                  let text = try? String(contentsOf: authorizedFile, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap { line in
                guard let raw = Self.rawKey(String(line)) else { return nil }
                let wire = Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + raw
                let id = "SHA256:" + Data(SHA256.hash(data: wire)).base64EncodedString().replacingOccurrences(of: "=", with: "")
                return BrowserKey(id: id, label: "Authorized Ed25519 key", raw: raw)
            }
        }
        lock.lock(); defer { lock.unlock() }; return keys
    }
    static func rawKey(_ text: String) -> Data? {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] == "ssh-ed25519", let data = Data(base64Encoded: String(fields[1])), data.count == 51,
              data.prefix(4) == Data([0,0,0,11]), String(data: data.subdata(in: 4..<15), encoding: .utf8) == "ssh-ed25519", data.subdata(in: 15..<19) == Data([0,0,0,32]) else { return nil }
        return data.subdata(in: 19..<51)
    }
    @discardableResult func add(_ text: String, label: String) -> Bool {
        guard authorizedFile == nil, let raw = Self.rawKey(text) else { return false }
        lock.lock(); defer { lock.unlock() }
        guard keys.count < 32 else { return false }
        let id = "SHA256:" + Data(SHA256.hash(data: raw)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        if !keys.contains(where: { $0.id == id }) { keys.append(BrowserKey(id: id, label: String(label.prefix(80)), raw: raw)); saveLocked() }
        return true
    }
    func verify(publicKey: String, signature: String, challenge: Data) -> Bool {
        guard let raw = Data(base64Encoded: publicKey), let signature = Data(base64Encoded: signature), raw.count == 32, signature.count == 64,
              all.contains(where: { $0.raw == raw }), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(signature, for: challenge)
    }
    func remove(_ id: String) { lock.lock(); keys.removeAll { $0.id == id }; saveLocked(); lock.unlock(); onRevoke?() }
    private func saveLocked() {
        if let file, let data = try? JSONEncoder().encode(keys) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? data.write(to: file, options: .atomic); try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
    }
}
