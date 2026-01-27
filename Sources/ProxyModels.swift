import Foundation

// MARK: - Teleport Configuration
struct TeleportConfiguration {
    var teleportProxy: String = "teleport.example.com"
    var jumpboxHost: String = "myjumpserver.example.com"
    var localPort: String = "2222"
    var tshPath: String = "/Applications/tsh.app/Contents/MacOS/tsh"
}

// MARK: - HTTP Proxy Configuration
struct HttpProxyConfiguration {
    var enabled: Bool = false
    var port: String = "8080"
    var path: String = "/usr/local/bin/hpts"
}

// MARK: - Launchctl Service Model
struct LaunchctlService: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var launchctlLabel: String
    var port: Int?
    var description: String
    var category: ServiceCategory
    var isEnabled: Bool

    init(id: UUID = UUID(), name: String, launchctlLabel: String,
         port: Int? = nil, description: String = "",
         category: ServiceCategory = .general, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.launchctlLabel = launchctlLabel
        self.port = port
        self.description = description
        self.category = category
        self.isEnabled = isEnabled
    }

    var displayName: String {
        if let port = port {
            return "\(name) (\(port))"
        }
        return name
    }
}

// MARK: - Service Category
enum ServiceCategory: String, Codable, CaseIterable {
    case proxy = "Proxies"
    case tunnel = "Tunnels"
    case database = "Databases"
    case development = "Development"
    case general = "General"

    var displayName: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .proxy: return 0
        case .tunnel: return 1
        case .database: return 2
        case .development: return 3
        case .general: return 4
        }
    }
}

// MARK: - Service Status
enum ServiceStatus: Equatable {
    case running(pid: Int32)
    case stopped
    case notLoaded
    case unknown

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var displayString: String {
        switch self {
        case .running(let pid): return "Running (PID: \(pid))"
        case .stopped: return "Stopped"
        case .notLoaded: return "Not Loaded"
        case .unknown: return "Unknown"
        }
    }

    var statusIcon: String {
        switch self {
        case .running: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .notLoaded: return "xmark.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - App Configuration
struct AppConfiguration {
    var teleport = TeleportConfiguration()
    var httpProxy = HttpProxyConfiguration()
    var services: [LaunchctlService] = []
    var showNotifications: Bool = true
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

// MARK: - UserDefaults Keys
struct ConfigKeys {
    static let teleportProxy = "teleportProxy"
    static let jumpboxHost = "jumpboxHost"
    static let localPort = "localPort"
    static let tshPath = "tshPath"
    static let httpProxyEnabled = "httpProxyEnabled"
    static let httpProxyPort = "httpProxyPort"
    static let httpProxyPath = "httpProxyPath"
    static let killExistingProcesses = "killExistingProcesses"
    static let showNotifications = "showNotifications"
    static let launchctlServices = "launchctlServices"
}
