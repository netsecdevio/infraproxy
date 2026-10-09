import Foundation

// A terminal belongs to the workspace, not to a browser socket.
final class TerminalSession {
    let id: String, name: String, directory: String, kind: String, owner: String
    let created: Date
    private(set) var ended: Date?
    private(set) var exitCode: Int32?
    private(set) var output = Data()
    private(set) var offset = 0
    private(set) var cols = 80, rows = 24
    var observers: [UUID: (Data) -> Void] = [:]
    var finished: ((Int32) -> Void)?
    var changed: (() -> Void)?
    private let queue: DispatchQueue, helper: URL
    private let inputQueue = DispatchQueue(label: "InfraProxy.pty.input")
    private var child: Process?, input: FileHandle?, reader: FileHandle?
    private var pendingInput = 0
    var running: Bool { ended == nil }
    var metadata: [String: Any] {
        var result: [String: Any] = ["id": id, "name": name, "directory": directory, "kind": kind, "created": created.timeIntervalSince1970, "state": running ? "running" : "exited", "cols": cols, "rows": rows, "offset": offset, "length": output.count, "owner": owner]
        if let ended { result["ended"] = ended.timeIntervalSince1970 }
        if let exitCode { result["exitCode"] = exitCode }
        return result
    }
    init(id: String = UUID().uuidString, name: String, directory: String, kind: String, owner: String, queue: DispatchQueue, helper: URL, created: Date = Date()) {
        self.id = id; self.name = name; self.directory = directory; self.kind = kind; self.owner = owner; self.queue = queue; self.helper = helper; self.created = created
    }
    func restore(output: Data, offset: Int, ended: Date, exitCode: Int32?) {
        self.output = Data(output.suffix(262144)); self.offset = offset; self.ended = ended; self.exitCode = exitCode
    }
    func launch(arguments: [String] = []) {
        let process = Process(); process.executableURL = helper
        let sessionHome = FileManager.default.temporaryDirectory.appendingPathComponent("infravibe-session-" + id, isDirectory: true)
        let profile = helper.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/terminal.sb")
        do {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"), FileManager.default.fileExists(atPath: profile.path) else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.createDirectory(at: sessionHome, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch { ended = Date(); exitCode = -1; finished?(-1); finished = nil; changed?(); return }
        process.arguments = [directory, "/usr/bin/sandbox-exec", "-f", profile.path,
            "-D", "WORKSPACE=" + URL(fileURLWithPath: directory).resolvingSymlinksInPath().path,
            "-D", "SESSION_HOME=" + sessionHome.resolvingSymlinksInPath().path] + (arguments.isEmpty ? ["/bin/zsh", "-f"] : arguments)
        // Never inherit credentials, SSH agent sockets, or host shell initialization.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": sessionHome.path,
            "TMPDIR": sessionHome.path, "ZDOTDIR": sessionHome.path, "LANG": "en_US.UTF-8"]
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        child = process; input = stdin.fileHandleForWriting; reader = stdout.fileHandleForReading
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.queue.async {
                if data.isEmpty { handle.readabilityHandler = nil; return }
                self.output.append(data)
                if self.output.count > 262144 { let trim = self.output.count - 262144; self.output = Data(self.output.dropFirst(trim)); self.offset += trim }
                for observer in self.observers.values { observer(data) }
                self.changed?()
            }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.queue.asyncAfter(deadline: .now() + 0.1) {
                self.ended = Date(); self.exitCode = process.terminationStatus
                self.finished?(process.terminationStatus); self.finished = nil
                self.reader?.readabilityHandler = nil; self.reader = nil; self.input = nil; self.child = nil
                self.changed?()
            }
        }
        do { try process.run() } catch { ended = Date(); exitCode = -1; finished?(-1); finished = nil; changed?() }
    }
    func write(_ data: Data) {
        guard running, let input else { return }
        pendingInput += data.count
        guard pendingInput <= 262144 else { stop(); return }
        inputQueue.async { [weak self] in
            let success = (try? input.write(contentsOf: data)) != nil
            guard let self else { return }
            self.queue.async { self.pendingInput -= data.count; if !success { self.stop() } }
        }
    }
    func sendInput(_ text: String) {
        let data = Data(text.utf8), count = UInt32(data.count)
        guard data.count <= 32768 else { return }
        write(Data([73, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]) + data)
    }
    func resize(cols: Int, rows: Int) {
        guard (2...500).contains(cols), (2...500).contains(rows) else { return }
        self.cols = cols; self.rows = rows
        write(Data([82, UInt8(cols >> 8), UInt8(cols & 255), UInt8(rows >> 8), UInt8(rows & 255)]))
    }
    func stop() {
        guard running else { return }
        ended = Date(); try? input?.close(); input = nil
        if let child, child.isRunning { child.terminate() }
        changed?()
    }
}

final class TerminalHistory {
    let directory: URL?
    init(directory: URL?) {
        self.directory = directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    func save(_ session: TerminalSession) {
        guard let directory, UUID(uuidString: session.id) != nil else { return }
        var object = session.metadata; object["output"] = session.output.base64EncodedString()
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let file = directory.appendingPathComponent(session.id + ".json")
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func load(queue: DispatchQueue, helper: URL) -> [TerminalSession] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil && $0.pathExtension == "json" }.prefix(100).compactMap { file in
            guard (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 < 400000 }) == true,
                  let data = try? Data(contentsOf: file), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = value["id"] as? String, id == file.deletingPathExtension().lastPathComponent,
                  let name = value["name"] as? String, let cwd = value["directory"] as? String, let kind = value["kind"] as? String,
                  let created = value["created"] as? Double, let encoded = value["output"] as? String, let output = Data(base64Encoded: encoded) else { return nil }
            let session = TerminalSession(id: id, name: name, directory: cwd, kind: kind, owner: value["owner"] as? String ?? "human", queue: queue, helper: helper, created: Date(timeIntervalSince1970: created))
            session.restore(output: output, offset: value["offset"] as? Int ?? 0, ended: Date(timeIntervalSince1970: value["ended"] as? Double ?? created), exitCode: (value["exitCode"] as? NSNumber)?.int32Value)
            return session
        }
    }
    func remove(_ id: String) {
        guard let directory, UUID(uuidString: id) != nil else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + ".json"))
    }
}


enum SessionWorkspaces {
    static var defaultURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("infravibe-workspace", isDirectory: true) }
    static var roots: [URL] { ([defaultURL.path] + (UserDefaults.standard.stringArray(forKey: "approvedSessionWorkspaces") ?? [])).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } }
    static func permits(_ directory: String) -> Bool {
        let path = URL(fileURLWithPath: directory).resolvingSymlinksInPath().path
        return roots.contains { path == $0.path || path.hasPrefix($0.path + "/") }
    }
    static func approve(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home + "/"), !path.hasPrefix(home + "/."), !path.hasPrefix(home + "/Library"), path != home else { return false }
        var paths = UserDefaults.standard.stringArray(forKey: "approvedSessionWorkspaces") ?? []
        if !paths.contains(path) { paths.append(path) }
        UserDefaults.standard.set(paths, forKey: "approvedSessionWorkspaces"); return true
    }
}
