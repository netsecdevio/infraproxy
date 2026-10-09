# Barklarm functional integration

Baseline: Vendor/barklarm at a6d2130d56c0ec249308c68afd8b1c1bdb19aea6.
The complete operator workflow, not just its polling adapters, is the acceptance target.

## Acceptance checklist

- [x] All ten upstream provider adapters and configuration fields.
- [x] Guided setup: provider selection, credential guidance, test before saving, review.
- [x] Link-based setup corresponding to upstream observersfromLinkParser.
- [x] Monitor management: edit, remove, mute, organize and status filtering.
- [x] Configurable polling and pause/resume; distinguish stale, unavailable, and healthy.
- [x] Import/export of monitors and general settings with explicit credential handling.
- [x] Per-monitor and global issue endpoints with reviewed, explicit issue submission.
- [x] Notification controls and persisted per-monitor mute.
- [x] Native status overview and quick access to monitor details.
- [x] Upgrade preserves existing 2.9 monitor credentials and IDs.
- [x] Tests cover setup, migration, configuration round-trip, issue payload/redaction,
      mute/polling and error paths, plus real rendered UI verification.
- [ ] Signed Universal release, Homebrew update and installed runtime verification.

## Intentional replacements

- SwiftUI operations workspace replaces the standalone Electrobun desktop shell.
- macOS Keychain replaces plaintext credential persistence.
- TLS verification cannot be disabled. Imported disable-SSL settings are not honored.
- Existing infravibe update and login-item controls replace Barklarm application controls.
- External-account live validation is distinct from fixture and public-provider testing.

Upstream evidence: src/mainview/components/Observers, pages/General,
src/extensions/observersfromLinkParser.ts, src/bun/tray.ts and observer-manager.ts.

## Verification

- Both provider parsing and configuration tests exercise all ten adapters, legacy ID/credential migration, authenticated backup round-trips, wrong-password/tamper rejection, notification policy and failed-write atomicity.
- Mock issue transport verifies 2xx acceptance, error/redirect rejection and no automatic retry.
- Native UI: public infravibe GitHub workflow link, discovery of two workflows, successful connection test, grouped save, mute, pause, template export and reviewed merge. Temporary monitors were removed afterwards.
- Private provider accounts and downstream issue services are not claimed as live-validated. See Vendor/BARKLARM.md for API/version limits and intentional replacements.
