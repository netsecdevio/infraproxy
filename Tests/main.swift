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
