import Foundation
let arguments = CommandLine.arguments
let key = BrowserSecurity.token()
let server = BrowserEngine(assets: URL(fileURLWithPath: arguments[1]), helper: URL(fileURLWithPath: arguments[2]))
let port = Int(arguments[3])!
server.onState = { running, _, _, _ in
    if running {
        let data = try! JSONSerialization.data(withJSONObject: ["key": key, "port": port])
        FileManager.default.createFile(atPath: arguments[4], contents: data, attributes: [.posixPermissions: 0o600])
    }
}
server.start(port: port, key: key)
server.update(snapshot: ["version": "test", "listeners": [], "sharing": [], "teleport": "Unavailable"], remoteURLs: [URL(string: "https://browser-test.example")!])
DispatchQueue.global().async {
    while let command = readLine() {
        if command == "rotate" { server.rotate(key: BrowserSecurity.token()) }
        if command == "stop" { server.stop() }
    }
}
RunLoop.main.run()
