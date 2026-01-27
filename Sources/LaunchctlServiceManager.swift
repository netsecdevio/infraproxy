import Foundation

// MARK: - Launchctl Service Manager
class LaunchctlServiceManager {

    // MARK: - Check Service Status
    /// Returns status for a launchctl service
    /// Uses: launchctl list <label>
    /// Exit code 0 = loaded, output contains PID if running
    func checkStatus(for service: LaunchctlService, completion: @escaping (ServiceStatus) -> Void) {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["list", service.launchctlLabel]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { proc in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                if proc.terminationStatus != 0 {
                    // Exit code != 0 means not loaded
                    completion(.notLoaded)
                } else {
                    // Parse output to extract PID
                    // When listing a single service, launchctl outputs in format:
                    // {
                    //     "PID" = <number>;
                    //     ...
                    // }
                    // Or for `launchctl list <label>` in older formats:
                    // PID\tStatus\tLabel
                    let status = self.parseStatus(from: output)
                    completion(status)
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(.unknown)
            }
        }
    }

    /// Synchronous status check for use in background threads
    func checkStatusSync(for service: LaunchctlService) -> ServiceStatus {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = ["list", service.launchctlLabel]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 {
                return .notLoaded
            }

            return parseStatus(from: output)
        } catch {
            return .unknown
        }
    }

    // MARK: - Start Service
    /// Starts a launchctl service
    /// Uses: launchctl start <label>
    func start(service: LaunchctlService, completion: @escaping (Result<Void, LaunchctlError>) -> Void) {
        executeCommand(arguments: ["start", service.launchctlLabel]) { result in
            completion(result)
        }
    }

    // MARK: - Stop Service
    /// Stops a launchctl service
    /// Uses: launchctl stop <label>
    func stop(service: LaunchctlService, completion: @escaping (Result<Void, LaunchctlError>) -> Void) {
        executeCommand(arguments: ["stop", service.launchctlLabel]) { result in
            completion(result)
        }
    }

    // MARK: - Restart Service
    /// Restarts a launchctl service (stop then start)
    func restart(service: LaunchctlService, completion: @escaping (Result<Void, LaunchctlError>) -> Void) {
        stop(service: service) { [weak self] stopResult in
            switch stopResult {
            case .success:
                // Wait a moment before starting
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self?.start(service: service, completion: completion)
                }
            case .failure:
                // If stop fails, try to start anyway (service might not have been running)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self?.start(service: service, completion: completion)
                }
            }
        }
    }

    // MARK: - Private Helpers

    private func executeCommand(arguments: [String], completion: @escaping (Result<Void, LaunchctlError>) -> Void) {
        let process = Process()
        process.launchPath = "/bin/launchctl"
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errorPipe

        process.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorMessage = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
                    completion(.failure(LaunchctlError.commandFailed(
                        code: proc.terminationStatus,
                        message: errorMessage.isEmpty ? "Command failed with exit code \(proc.terminationStatus)" : errorMessage
                    )))
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                completion(.failure(LaunchctlError.processError(error.localizedDescription)))
            }
        }
    }

    private func parseStatus(from output: String) -> ServiceStatus {
        // Try to parse PID from the output
        // launchctl list <label> outputs a plist-like format on newer macOS:
        // {
        //     "LimitLoadToSessionType" = "Aqua";
        //     "Label" = "com.example.service";
        //     "OnDemand" = true;
        //     "LastExitStatus" = 0;
        //     "PID" = 12345;
        // };

        // Look for PID in the output
        let pidPatterns = [
            #"\"PID\"\s*=\s*(\d+)"#,  // plist format: "PID" = 12345;
            #"PID\s*:\s*(\d+)"#,       // key: value format
            #"^(\d+)\t"#               // tab-separated format (first column)
        ]

        for pattern in pidPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
               let match = regex.firstMatch(in: output, options: [], range: NSRange(output.startIndex..., in: output)),
               let pidRange = Range(match.range(at: 1), in: output),
               let pid = Int32(output[pidRange]) {
                if pid > 0 {
                    return .running(pid: pid)
                }
            }
        }

        // If we got here with exit code 0 but no PID, service is loaded but not running
        // Check if output contains indicators that service is loaded
        if output.contains("Label") || output.contains("}") || !output.isEmpty {
            return .stopped
        }

        return .unknown
    }
}

// MARK: - Errors
enum LaunchctlError: LocalizedError {
    case commandFailed(code: Int32, message: String)
    case serviceNotFound(label: String)
    case processError(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let code, let message):
            return "launchctl command failed (code \(code)): \(message)"
        case .serviceNotFound(let label):
            return "Service not found: \(label)"
        case .processError(let message):
            return "Process error: \(message)"
        }
    }
}
