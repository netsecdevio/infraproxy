import Foundation

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
let large = OperationsCommand.run("/usr/bin/yes", ["test"], timeout: 0.1)
assert(large.code != 0 && large.output.count > 65536)
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
