# Barklarm integration

Upstream: https://github.com/alvarolorentedev/barklarm-app
Pinned source: `a6d2130d56c0ec249308c68afd8b1c1bdb19aea6` (Git submodule `Vendor/barklarm`).
Initialize with `git submodule update --init Vendor/barklarm`.

`Sources/DevOps.swift` adapts the upstream observer configurations and provider
logic to infravibe's native Swift runtime. The upstream desktop shell, package
scripts and JavaScript dependencies are not executed or bundled. Native builds
do not require fetching the submodule; it preserves the source and attribution
for review and maintenance.

The native integration includes GitHub Actions, Azure DevOps, Bitbucket Pipelines,
CCTray, Datadog, Sentry, New Relic, Opsgenie, Graylog and Grafana. Upstream JSON
exports with an `observables` array can be reviewed and imported in DevOps.
Unsupported types or invalid endpoints reject the import as a whole. Import
creates independent monitors; subsequent edits in Barklarm are not synchronized.

Configuration, including credentials, is saved in macOS Keychain, not UserDefaults
or exported JSON. The original import file remains unchanged and may contain
plaintext secrets. Requests are read-only, HTTPS-only, timeout and size limited,
with redirects disabled and normal TLS certificate validation. Cloud API sites
are restricted to supported vendor regions. Custom Azure, CCTray, Graylog and
Grafana endpoints must be reviewed by the local owner. These are app-level
provider requests, not terminal sandbox network grants.

Checks run every 60 seconds with at most four simultaneous requests. Previously
configured monitors resume on launch after Keychain unlock. Status failures remain
unavailable rather than green. Opt-in notifications report failure/recovery
transitions without copying provider response bodies or secrets into notifications.
The menu summary opens the DevOps tab. No remote configuration endpoint is exposed.

Corrections relative to upstream:
- Keep TLS verification enabled for Opsgenie.
- Cancelled Bitbucket/GitHub runs are unavailable, not failed/successful.
- Grafana reads live Prometheus-compatible alert rule states, not provisioning
  `execErrState` (which specifies error behavior, not current health).
- Sentry requests unresolved issues; New Relic requests open violations.
- External XML entities/DTDs are rejected.

Validation uses provider response fixtures for all ten adapters. Live authenticated
validation still requires the operator's accounts/endpoints; fixture coverage does
not prove compatibility with every hosted version, region or enterprise deployment.
Some inherited APIs (especially Graylog/New Relic) may be unavailable on newer
provider versions and will display Unavailable. This is monitoring, not provider
administration or a full issue/PR management client.

Upstream package.json declares MIT. It does not contain a standalone LICENSE file.
The declared MIT terms and author attribution are preserved in THIRD_PARTY_NOTICES.md.
