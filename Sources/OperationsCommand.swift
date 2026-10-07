import Foundation

struct CommandResult {
    let code: Int32
    let output: String
    var diagnostic: String = ""
}

// Cancellation is shared with the worker without exposing a Process to the UI.
final class CommandControl {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let stop = cancelled
        lock.unlock()
        if stop { terminate(process) }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let process = process
        lock.unlock()
        if let process { terminate(process) }
    }
    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
private final class CommandBuffer {
    private let lock = NSLock()
    private var data = Data()
    func set(_ data: Data) { lock.lock(); self.data = data; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
enum OperationsCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 25, control: CommandControl? = nil) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/local/google-cloud-sdk/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"
        process.environment = environment
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let control = control ?? CommandControl()
        if control.isCancelled { return CommandResult(code: -1, output: "", diagnostic: "Cancelled") }
        do {
            try process.run()
            control.attach(process)
            let deadline = DispatchWorkItem { control.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
            // Drain both pipes concurrently: warnings must not corrupt JSON or block a full pipe.
            let buffer = CommandBuffer()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                buffer.set(errors.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()
            deadline.cancel()
            return CommandResult(code: control.isCancelled ? -1 : process.terminationStatus,
                                 output: String(decoding: data, as: UTF8.self),
                                 diagnostic: control.isCancelled ? "Command cancelled or timed out." : buffer.text)
        } catch { return CommandResult(code: -1, output: "", diagnostic: error.localizedDescription) }
    }
    static func quote(_ value: String) -> String { "\u{27}" + value.replacingOccurrences(of: "\u{27}", with: "\u{27}\\\u{27}\u{27}") + "\u{27}" }
}
