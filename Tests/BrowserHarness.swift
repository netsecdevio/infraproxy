import Foundation
import CryptoKit
let arguments = CommandLine.arguments
let key = BrowserSecurity.token()
let agentStore = AgentAccess()
let readToken = agentStore.create(name: "Read fixture", hours: 1)!
let controlToken = agentStore.create(name: "Control fixture", hours: 1)!
agentStore.approveControl(agentStore.authenticate(controlToken)!.id)
let browserKeys = BrowserKeys()
let browserPrivate = Curve25519.Signing.PrivateKey()
let browserRaw = browserPrivate.publicKey.rawRepresentation
let wire = Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + browserRaw
browserKeys.add("ssh-ed25519 " + wire.base64EncodedString(), label: "Test browser")
let server = BrowserEngine(assets: URL(fileURLWithPath: arguments[1]), helper: URL(fileURLWithPath: arguments[2]), historyDirectory: URL(fileURLWithPath: arguments[4]).deletingLastPathComponent().appendingPathComponent("history"), agents: agentStore, browserKeys: browserKeys)
let port = Int(arguments[3])!
server.onState = { running, _, _, _ in
    if running {
        let data = try! JSONSerialization.data(withJSONObject: ["key": key, "port": port, "readToken": readToken, "controlToken": controlToken, "privateKey": browserPrivate.rawRepresentation.base64EncodedString(), "publicKey": browserRaw.base64EncodedString()])
        FileManager.default.createFile(atPath: arguments[4], contents: data, attributes: [.posixPermissions: 0o600])
    }
}
server.start(port: port, key: key)
server.update(snapshot: ["version": "test", "listeners": [], "sharing": [], "teleport": "Unavailable"], remoteURLs: [URL(string: "https://browser-test.example")!])
DispatchQueue.global().async {
    while let command = readLine() {
        if command == "rotate" { server.rotate(key: BrowserSecurity.token()) }
        if command == "stop" { server.stop() }
        if command == "revoke-agent", let grant = agentStore.authenticate(controlToken) { agentStore.revoke(grant.id) }
    }
}
RunLoop.main.run()
