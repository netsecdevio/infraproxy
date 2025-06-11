import Foundation

// MARK: - Configuration Model
struct ProxyConfiguration {
    var teleportProxy: String = "teleport.example.com"
    var jumpboxHost: String = "myjumpserver.example.com"
    var localPort: String = "2222"
    var tshPath: String = "/Applications/tsh.app/Contents/MacOS/tsh"
    var killExistingProcesses: Bool = false
}

// MARK: - Log Entry Model
struct LogEntry {
    let timestamp: Date
    let level: LogLevel
    let message: String
    
    enum LogLevel: String, CaseIterable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }
}
