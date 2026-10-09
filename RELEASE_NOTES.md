# infravibe 2.10.0

Barklarm’s operator workflows are now integrated into the native DevOps workspace.

- Guided setup with provider links, credential guidance, resource discovery, connection testing and review.
- Edit, duplicate, group, search, filter, mute and pause monitors. Stale results are distinguished from healthy checks.
- Configurable automatic polling, manual refresh, notification controls and login-at-startup preference.
- Review and merge/replace Barklarm configurations, encrypted backups and credential-free templates. Existing 2.9 monitors migrate with their IDs and credentials intact.
- Global or per-monitor issue endpoints, with an explicit payload review before submission. Provider credentials are excluded; failed submissions are not automatically retried.
- Credentials remain in Keychain. Backups use password-protected AES-GCM. TLS validation remains mandatory.

All ten provider adapters have fixture coverage. Live public GitHub workflow discovery and monitoring were checked. Private-account and enterprise-provider compatibility still requires validation with those accounts; see Vendor/BARKLARM.md. This release provides monitoring and reviewed issue submission, not a complete issue/PR administration client.

Signed and notarized Universal macOS application for Apple silicon and Intel. SPIRE remains deferred.
