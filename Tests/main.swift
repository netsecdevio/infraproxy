import Foundation
import CryptoKit

let payload = """
{"active":{"profile_url":"https://other.example:443","valid_until":"2030-01-01T00:00:00Z"},"profiles":[{"profile_url":"https://target.example:443","valid_until":"2026-10-08T12:00:00.123Z"}]}
"""
let expiry = TeleportExpiry.parse(payload, proxy: "target.example")
assert(expiry != nil)
assert(TeleportExpiry.parse(payload, proxy: "missing.example") == nil)
assert(TeleportExpiry.parse("bad json", proxy: "target.example") == nil)
assert(TeleportExpiry.label(nil) == "Expiry unavailable")
assert(TeleportExpiry.label(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 1)) == "Expired — log in")
assert(TeleportExpiry.label(Date(timeIntervalSince1970: 3661), now: Date(timeIntervalSince1970: 0)) == "01:01:01")
let quoted = OperationsCommand.quote("a'b;$(echo unsafe)")
let roundTrip = OperationsCommand.run("/bin/sh", ["-c", "printf %s " + quoted])
assert(roundTrip.output == "a'b;$(echo unsafe)")
let large = OperationsCommand.run("/bin/sh", ["-c", "dd if=/dev/zero bs=65536 count=2 2>/dev/null; printf done"], timeout: 10)
assert(large.code == 0 && large.output.count == 131076 && large.output.hasSuffix("done"))
let timedCommand = OperationsCommand.run("/bin/sleep", ["10"], timeout: 0.1)
assert(timedCommand.code == -1)
let missing = OperationsCommand.run("/nonexistent/infraproxy", [])
assert(missing.code == -1)
let vm = try JSONDecoder().decode(VMInstance.self, from: Data("{\"name\":\"test\",\"zone\":\"projects/demo/zones/us-east1-b\",\"status\":\"RUNNING\"}".utf8))
assert(vm.shortZone == "us-east1-b")
print("PASS: profile selection, fractional expiry, unknown/expired/countdown, shell quoting, pipe draining, timeout, launch failure, GCP decoding")

let separated = OperationsCommand.run("/bin/sh", ["-c", "printf '[]'; printf 'warning' >&2"])
assert(separated.output == "[]" && separated.diagnostic == "warning")
let cancelled = CommandControl()
cancelled.cancel()
assert(OperationsCommand.run("/usr/bin/true", [], control: cancelled).code != 0)
assert(CloudCommands.login(account: nil) == ["auth", "login", "--force", "--no-activate", "--brief", "--launch-browser"])
assert(CloudCommands.login(account: "example@test.invalid").contains("example@test.invalid"))
let console = URLComponents(url: CloudCommands.consoleURL(path: "/logs/query", account: "a+b@test.invalid", project: "demo"), resolvingAgainstBaseURL: false)!
assert(console.queryItems?.first(where: { $0.name == "authuser" })?.value == "a+b@test.invalid")
let runResources = try CloudResource.parse(Data("""
[{"metadata":{"name":"hello","labels":{"cloud.googleapis.com/location":"us-east1"}},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]
""".utf8), kind: .run)
assert(runResources.first?.location == "us-east1" && runResources.first?.detail == "Ready")
let buckets = try CloudResource.parse(Data("""
[{"name":"bucket","location":"US","default_storage_class":"STANDARD"}]
""".utf8), kind: .buckets)
assert(buckets.first?.detail == "STANDARD")
assert((try? CloudResource.parse(Data("{}".utf8), kind: .sql)) == nil)

final class FakeCloud {
    var calls: [[String]] = []
    var noAccounts = false
    var denyProjects = false
    var badResources = false
    var failLogin = false
    var extraAccount = false
    private let lock = NSLock()
    func execute(_ path: String, _ args: [String], _ timeout: TimeInterval, _ control: CommandControl?) -> CommandResult {
        lock.lock(); defer { lock.unlock() }
        calls.append(args)
        if args.starts(with: ["auth", "login"]) {
            if control?.isCancelled == true || failLogin { return CommandResult(code: 1, output: "SENSITIVE_AUTH_CODE", diagnostic: "SENSITIVE_AUTH_URL") }
            extraAccount = true
            return CommandResult(code: 0, output: "SENSITIVE_AUTH_CODE")
        }
        if args.starts(with: ["auth", "list"]) {
            if noAccounts { return CommandResult(code: 0, output: "[]") }
            return CommandResult(code: 0, output: extraAccount ? "[{\"account\":\"a@test.invalid\",\"status\":\"ACTIVE\"},{\"account\":\"b@test.invalid\",\"status\":\"\"}]" : "[{\"account\":\"a@test.invalid\",\"status\":\"ACTIVE\"}]")
        }
        if args.starts(with: ["config", "get-value"]) { return CommandResult(code: 0, output: "project-a\n") }
        if args.starts(with: ["projects", "list"]) {
            if denyProjects { return CommandResult(code: 1, output: "", diagnostic: "Permission denied") }
            let project = args.contains("--account=b@test.invalid") ? "project-b" : "project-a"
            return CommandResult(code: 0, output: "[{\"projectId\":\"\(project)\",\"name\":\"Test\",\"lifecycleState\":\"ACTIVE\"},{\"projectId\":\"deleted\",\"lifecycleState\":\"DELETE_REQUESTED\"}]")
        }
        if badResources { return CommandResult(code: 0, output: "invalid") }
        if args.starts(with: ["compute", "instances", "list"]) {
            return CommandResult(code: 0, output: "[{\"name\":\"vm\",\"zone\":\"zones/us-east1-b\",\"status\":\"TERMINATED\"}]")
        }
        return CommandResult(code: 0, output: "[]")
    }
}
func waitForCloud(_ model: GoogleCloudModel) {
    let deadline = Date().addingTimeInterval(5)
    while model.busy && Date() < deadline { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    assert(!model.busy, "Cloud operation did not finish")
}
let suiteName = "InfraProxy.Tests." + UUID().uuidString
let preferences = UserDefaults(suiteName: suiteName)!
defer { preferences.removePersistentDomain(forName: suiteName) }
let fake = FakeCloud()
let cloud = GoogleCloudModel(defaults: preferences, sdkResolver: { _ in "/fake/gcloud" }, runner: fake.execute)
cloud.discover()
waitForCloud(cloud)
assert(cloud.account == "a@test.invalid" && cloud.project == "project-a")
assert(cloud.projects.count == 1 && cloud.instances.count == 1 && cloud.canOperate)
assert(fake.calls.contains(where: { $0.contains("--account=a@test.invalid") && $0.contains("--project=project-a") }))
cloud.selectProject("injected-project")
assert(cloud.project == "project-a")
cloud.login()
assert(cloud.authenticating && !cloud.canOperate && cloud.instances.isEmpty)
waitForCloud(cloud)
assert(cloud.account == "b@test.invalid" && cloud.project == "project-b")
assert(!cloud.message.contains("SENSITIVE"))
cloud.selectAccount("a@test.invalid")
assert(cloud.instances.isEmpty && !cloud.canOperate)
waitForCloud(cloud)
assert(cloud.project == "project-a")
cloud.operate("start", instance: cloud.instances[0])
waitForCloud(cloud)
assert(fake.calls.contains(where: { $0.starts(with: ["compute", "instances", "start", "vm"]) && $0.contains("--account=a@test.invalid") && $0.contains("--project=project-a") && $0.contains("--zone=us-east1-b") }))
fake.badResources = true
cloud.refreshResources()
waitForCloud(cloud)
assert(cloud.instances.isEmpty && !cloud.canOperate && cloud.message.contains("Unable to load"))
fake.badResources = false
fake.failLogin = true
cloud.login(reauthenticate: true)
waitForCloud(cloud)
assert(!cloud.message.contains("SENSITIVE") && cloud.message.contains("Sign-in did not complete"))
assert(fake.calls.contains(where: { $0.starts(with: ["auth", "login", "a@test.invalid"]) && $0.contains("--force") }))
fake.denyProjects = true
cloud.discover()
waitForCloud(cloud)
assert(cloud.projects.isEmpty && cloud.project.isEmpty && !cloud.canOperate)
fake.denyProjects = false
fake.noAccounts = true
cloud.discover()
waitForCloud(cloud)
assert(cloud.account.isEmpty && cloud.message.contains("Sign in with Google"))
let noSDK = GoogleCloudModel(defaults: preferences, sdkResolver: { _ in nil }, runner: fake.execute)
noSDK.discover()
assert(noSDK.sdkPath == nil && noSDK.message.contains("could not be found"))
print("PASS: discovery, account/project scoping, deleted projects, automatic login refresh, account switching, power-action arguments, malformed data, expired auth, secret suppression, missing CLI, resource decoding, and separated diagnostics")

let tailFixture = #"{"BackendState":"Running","Self":{"DNSName":"host.example.ts.net."},"Peer":{"a":{"ID":"a","HostName":"offline","Online":false},"b":{"ID":"b","HostName":"online","Online":true,"TailscaleIPs":["100.64.0.2"]}}}"#
let tailStatus = try JSONDecoder().decode(TailStatus.self, from: Data(tailFixture.utf8))
assert(tailStatus.connected && tailStatus.hostname == "host.example.ts.net")
assert(tailStatus.peers.map(\.id) == ["b", "a"] && tailStatus.peers.last?.address == "")
assert(RemoteCommands.port("3000", blocked: [1080]) == 3000)
for port in ["0", "65536", "1080", "3000;touch /tmp/bad", "３０００"] { assert(RemoteCommands.port(port, blocked: [1080]) == nil) }
assert(try! RemoteCommands.portInUse(#"{"TCP":{"8443":{}}}"#))
assert(try! RemoteCommands.portInUse(#"{"Foreground":{"session":{"Web":{"host:8443":{}}}}}"#))
assert(try! !RemoteCommands.portInUse(#"{"TCP":{"443":{}}}"#))
assert(try! !RemoteCommands.portInUse("null"))
assert(RemoteCommands.arguments(.tailscale, port: 3000) == ["serve", "--https=8443", "http://127.0.0.1:3000"])
assert(RemoteCommands.arguments(.funnel, port: 3000).first == "funnel")
assert(RemoteCommands.endpoint(in: "https://valid-name.trycloudflare.com \n", provider: .cloudflare)?.host == "valid-name.trycloudflare.com")
assert(RemoteCommands.endpoint(in: "https://valid.trycloudflare.com.evil.test", provider: .cloudflare) == nil)
assert(RemoteCommands.endpoint(in: "https://host.tail.ts.net:84430", provider: .tailscale) == nil)
let ownedTunnel = SharedTunnel()
ownedTunnel.start(executable: "/bin/sh", arguments: ["-c", "echo https://fixture-test.trycloudflare.com; echo Registered tunnel connection; exec sleep 30"], provider: .cloudflare)
let readyDeadline = Date().addingTimeInterval(3)
while !ownedTunnel.ready && Date() < readyDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(ownedTunnel.running && ownedTunnel.ready && ownedTunnel.url != nil)
ownedTunnel.stop()
let stopDeadline = Date().addingTimeInterval(4)
while ownedTunnel.running && Date() < stopDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(!ownedTunnel.running && !ownedTunnel.ready && ownedTunnel.url == nil)
print("PASS: Tailscale discovery, existing-share protection, safe port validation, provider arguments, URL validation, owned tunnel readiness and shutdown")

assert(RemoteCommands.arguments(.ngrok, port: 4020) == ["http", "http://127.0.0.1:4020", "--log=stdout", "--log-format=json", "--log-level=info", "--inspect=false"])
assert(RemoteCommands.endpoint(in: #"{"msg":"started tunnel","url":"https://test.ngrok-free.app"}"#, provider: .ngrok)?.host == "test.ngrok-free.app")
assert(RemoteCommands.endpoint(in: #"{"msg":"error","url":"https://dashboard.ngrok.com"}"#, provider: .ngrok) == nil)
assert(RemoteCommands.endpoint(in: #"{"msg":"started tunnel","url":"https://secret@example.com"}"#, provider: .ngrok) == nil)
let request = try BrowserRequest.parse(Data("POST /api/login HTTP/1.1\r\nHost: localhost:4020\r\nOrigin: http://localhost:4020\r\nContent-Length: 2\r\n\r\n{}".utf8))
assert(request?.sameOrigin == true && request?.body == Data("{}".utf8))
assert(BrowserSecurity.equal("same", "same") && !BrowserSecurity.equal("same", "diff"))
print("PASS: ngrok agent arguments and URL parsing; browser request origin and authentication comparison")

let ngrokFixture = SharedTunnel()
ngrokFixture.start(executable: "/bin/sh", arguments: ["-c", "printf '%s\\n' '{\"msg\":\"started tunnel\",\"url\":\"https://fixture.ngrok-free.app\"}'; exec sleep 30"], provider: .ngrok, localPort: 4021)
let ngrokDeadline = Date().addingTimeInterval(3)
while !ngrokFixture.ready && Date() < ngrokDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(ngrokFixture.running && ngrokFixture.ready && ngrokFixture.url?.host == "fixture.ngrok-free.app" && ngrokFixture.localPort == 4021)
ngrokFixture.stop()
let ngrokStopDeadline = Date().addingTimeInterval(4)
while ngrokFixture.running && Date() < ngrokStopDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
assert(!ngrokFixture.running && !ngrokFixture.ready && ngrokFixture.url == nil && ngrokFixture.localPort == nil)
print("PASS: owned ngrok process readiness, destination tracking, and shutdown")

let agentStore = AgentAccess()
let agentToken = agentStore.create(name: "Fixture", hours: 1)!
let agentGrant = agentStore.authenticate(agentToken)!
assert(!agentGrant.canControl && agentStore.authenticate(agentToken + "bad") == nil)
agentStore.requestControl(agentGrant.id)
assert(agentStore.grant(agentGrant.id)!.requestedControl && !agentStore.grant(agentGrant.id)!.canControl)
agentStore.approveControl(agentGrant.id)
assert(agentStore.grant(agentGrant.id)!.canControl)
agentStore.revoke(agentGrant.id)
assert(agentStore.authenticate(agentToken) == nil)
let signingKey = Curve25519.Signing.PrivateKey()
let rawPublic = signingKey.publicKey.rawRepresentation
let wirePublic = Data([0,0,0,11]) + Data("ssh-ed25519".utf8) + Data([0,0,0,32]) + rawPublic
let browserKeys = BrowserKeys()
assert(browserKeys.add("ssh-ed25519 " + wirePublic.base64EncodedString(), label: "Fixture"))
let challengeData = Data("challenge".utf8), signatureData = try signingKey.signature(for: challengeData)
assert(browserKeys.verify(publicKey: rawPublic.base64EncodedString(), signature: signatureData.base64EncodedString(), challenge: challengeData))
assert(!browserKeys.verify(publicKey: rawPublic.base64EncodedString(), signature: signatureData.base64EncodedString(), challenge: Data("other".utf8)))
browserKeys.remove(browserKeys.all[0].id)
assert(!browserKeys.verify(publicKey: rawPublic.base64EncodedString(), signature: signatureData.base64EncodedString(), challenge: challengeData))
print("PASS: separate agent identity, local-only approval, revocation, Ed25519 browser proof, and key revocation")

let authorizedFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: authorizedFixture) }
let publicLine = "ssh-ed25519 " + wirePublic.base64EncodedString() + " fixture\n"
try publicLine.write(to: authorizedFixture, atomically: true, encoding: .utf8)
let authorizedStore = BrowserKeys(authorizedFile: authorizedFixture)
assert(authorizedStore.verify(publicKey: rawPublic.base64EncodedString(), signature: signatureData.base64EncodedString(), challenge: challengeData))
assert(!authorizedStore.add(publicLine, label: "No remote enrollment"))
var invalidated = false
 authorizedStore.onRevoke = { invalidated = true }
authorizedStore.refreshAuthorization()
try ("restrict " + publicLine).write(to: authorizedFixture, atomically: true, encoding: .utf8)
authorizedStore.refreshAuthorization()
assert(invalidated && authorizedStore.all.isEmpty)
assert(!authorizedStore.verify(publicKey: rawPublic.base64EncodedString(), signature: signatureData.base64EncodedString(), challenge: challengeData))
assert(SessionWorkspaces.permits(SessionWorkspaces.defaultURL.path))
assert(!SessionWorkspaces.permits(FileManager.default.homeDirectoryForCurrentUser.path))
print("PASS: authorized_keys source, restricted-entry denial, revocation and workspace scope")

// Barklarm adapter fixtures: failures and missing data must never become healthy.
func monitorHealth(_ type: String, _ json: String, fields: [String:String] = [:]) throws -> DevOpsHealth {
    try DevOpsAdapter.parse(Data(json.utf8), monitor: DevOpsMonitor(type: type, fields: fields)).health
}
assert(try! monitorHealth("githubAction", #"{"workflow_runs":[{"status":"completed","conclusion":"failure"}]}"#) == .failed)
assert(try! monitorHealth("githubAction", #"{"workflow_runs":[{"status":"completed","conclusion":"cancelled"}]}"#) == .unknown)
assert(try! monitorHealth("githubAction", #"{"workflow_runs":[{"status":"in_progress"}]}"#) == .running)
assert(try! monitorHealth("azureDevOps", #"{"value":[{"state":"completed","result":"succeeded"}]}"#) == .healthy)
assert(try! monitorHealth("bitbucket", #"{"values":[{"state":{"name":"COMPLETED","result":{"name":"STOPPED"}}}]}"#) == .unknown)
assert(try! monitorHealth("bitbucket", #"{"values":[{"state":{"name":"COMPLETED","result":{"name":"FAILED"}}}]}"#) == .failed)
assert(try! monitorHealth("datadogMonitor", #"{"overall_state":"Alert"}"#) == .failed)
assert(try! monitorHealth("sentry", "[]") == .healthy)
assert(try! monitorHealth("newRelic", #"{"violations":[{"id":1}]}"#) == .failed)
assert(try! monitorHealth("opsgenie", #"{"data":{"status":"closed"}}"#) == .healthy)
assert(try! monitorHealth("graylog", #"{"total":0}"#) == .healthy)
assert(try! monitorHealth("grafana", #"{"status":"success","data":{"groups":[{"rules":[{"type":"alerting","state":"firing","health":"ok"}]}]}}"#) == .failed)
assert(try! monitorHealth("grafana", #"{"status":"success","data":{"groups":[]}}"#) == .unknown)
assert(try! monitorHealth("ccTray", #"<Projects><Project name="api" activity="Sleeping" lastBuildStatus="Success" /></Projects>"#) == .healthy)
assert((try? monitorHealth("ccTray", #"<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><Projects/>"#)) == nil)
assert((try? monitorHealth("sentry", "{}")) == nil)
assert(DevOpsAdapter.url("http://example.com") == nil)
assert(DevOpsAdapter.url("https://user:password@example.com") == nil)
assert((try? DevOpsAdapter.request(DevOpsMonitor(type:"opsgenie", fields:["host":"evil.test", "identifier":"id", "apiKey":"fixture"]))) == nil)
let barkImport = try DevOpsAdapter.imported(Data(#"{"observables":[{"type":"githubAction","owner":"example","repo":"repo","workflowId":42,"authToken":"fixture","muted":true}]}"#.utf8))
assert(barkImport.count == 1 && barkImport[0].fields["workflowId"] == "42" && barkImport[0].muted)
let barkRequest = try DevOpsAdapter.request(barkImport[0])
assert(barkRequest.url?.host == "api.github.com" && barkRequest.value(forHTTPHeaderField:"Authorization") == "Bearer fixture")
assert((try? DevOpsAdapter.imported(Data(#"{"observables":[{"type":"unknown"}]}"#.utf8))) == nil)
print("PASS: ten Barklarm adapters, cancelled/unknown states, configuration import, HTTPS and credential destination restrictions, XML entity rejection")

if ProcessInfo.processInfo.environment["INFRAVIBE_DEVOPS_LIVE_TEST"] == "1" {
    var liveDone = false
    var livePassed = false
    Task { @MainActor in
        do {
            let monitor = DevOpsMonitor(type: "githubAction", fields: ["owner":"netsecdevio", "repo":"infravibe", "workflowId":"ci.yml"])
            let data = try await DevOpsHTTP().fetch(DevOpsAdapter.request(monitor))
            let result = try DevOpsAdapter.parse(data, monitor: monitor)
            guard result.link?.host == "github.com" else { throw DevOpsError.invalidResponse }
            print("PASS: live public GitHub Actions adapter: " + result.health.rawValue)
            livePassed = true
        } catch { print("FAIL: live public GitHub Actions adapter") }
        liveDone = true
    }
    let deadline = Date().addingTimeInterval(35)
    while !liveDone && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    assert(liveDone && livePassed)
}
