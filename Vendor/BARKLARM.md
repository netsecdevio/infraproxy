# Barklarm integration

Upstream: https://github.com/alvarolorentedev/barklarm-app
Pinned source: `a6d2130d56c0ec249308c68afd8b1c1bdb19aea6` (Git submodule `Vendor/barklarm`).
Initialize with `git submodule update --init Vendor/barklarm`.

`Sources/DevOps.swift`, `DevOpsConfiguration.swift` and `DevOpsWorkspace.swift`
adapt the upstream setup, configuration, monitoring, notification and issue workflows to infravibe's native Swift runtime. The upstream desktop shell, package
scripts and JavaScript dependencies are not executed or bundled. Native builds
do not require fetching the submodule; it preserves the source and attribution
for review and maintenance.

The native integration includes GitHub Actions, Azure DevOps, Bitbucket Pipelines,
CCTray, Datadog, Sentry, New Relic, Opsgenie, Graylog and Grafana. Upstream JSON
exports with an `observables` array can be reviewed and imported in DevOps.
Unsupported types or invalid endpoints reject the import as a whole. Import
creates independent monitors; subsequent edits in Barklarm are not synchronized.

Configuration, including credentials, is saved in macOS Keychain, not UserDefaults
or plaintext exports. Password-protected backups use AES-256-GCM and
PBKDF2-HMAC-SHA256 (600,000 rounds), a random salt and nonce. Templates omit
credential fields and URL query parameters and import paused. The original import file remains unchanged and may contain
plaintext secrets. Monitoring requests are read-only, HTTPS-only, timeout and size limited,
with redirects disabled and normal TLS certificate validation. Cloud API sites
are restricted to supported vendor regions. Custom Azure, CCTray, Graylog and
Grafana endpoints must be reviewed by the local owner. These are app-level
provider requests, not terminal sandbox network grants.

Checks default to 60 seconds, configurable from 1–60 minutes, with at most four
simultaneous requests. Global automatic polling and individual monitors can be
paused; manual refresh remains available. Results older than the polling interval
plus 60 seconds are marked stale. Previously
configured monitors resume on launch after Keychain unlock. Status failures remain
unavailable rather than green. Opt-in notifications report failure/recovery
transitions, optionally including running/unavailable changes and sound. Per-monitor
mute suppresses alerts. Notifications contain no provider response bodies or secrets.
The menu summary opens the DevOps tab. No remote configuration endpoint is exposed.

Corrections relative to upstream:
- Keep TLS verification enabled for Opsgenie.
- Cancelled Bitbucket/GitHub runs are unavailable, not failed/successful.
- Grafana reads live Prometheus-compatible alert rule states, not provisioning
  `execErrState` (which specifies error behavior, not current health).
- Sentry requests unresolved issues; New Relic requests open violations.
- External XML entities/DTDs are rejected.

Setup provides credential guidance, tests, link parsing/drop, and first-page resource
discovery for GitHub Actions, Azure DevOps, CCTray, Datadog, Sentry, Opsgenie,
Graylog and Bitbucket. The original application also used manually supplied API
credentials; this does not introduce an OAuth account broker.

Issue endpoints are configured globally or per monitor. For a fresh failure, the
operator reviews the name, status, link and failure summary before an HTTPS POST.
The payload preserves Barklarm's numeric failure status (1), adds `statusLabel`,
and excludes configuration/credential fields and link query parameters. Redirects
are rejected and failed submissions are not retried automatically. An accepted
HTTP response is not proof that the downstream system created an issue.

Intentional replacements: native SwiftUI replaces Electrobun; Keychain and encrypted
backups replace plaintext persistence/exports; Sparkle and macOS login items replace
upstream app controls. Upstream disable-SSL settings are never honored. Import
merge retains current preferences, while replacement restores imported preferences.
The original import file is not modified. Imported polling is clamped to 1–60 minutes.

Validation uses provider response fixtures for all ten adapters, encrypted backup
round-trip/tamper tests, model persistence/failure tests and mock issue transport.
Live public GitHub workflow discovery, connection testing and native save/mute/pause,
template export/import were exercised on this Mac. Live authenticated
validation still requires the operator's accounts/endpoints; fixture coverage does
not prove compatibility with every hosted version, region or enterprise deployment.
Some inherited APIs (especially Graylog/New Relic) may be unavailable on newer
provider versions and will display Unavailable. This is monitoring, not provider
administration or a full issue/PR management client.

Upstream package.json declares MIT. It does not contain a standalone LICENSE file.
The declared MIT terms and author attribution are preserved in THIRD_PARTY_NOTICES.md.
