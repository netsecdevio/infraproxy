# infravibe 2.9.0

- Native DevOps monitoring adapted from Barklarm, with a compact live menu summary, a DevOps settings tab, configuration import, editing, and opt-in failure/recovery notifications.
- Adapters for GitHub Actions, Azure DevOps, Bitbucket Pipelines, CCTray, Datadog, Sentry, New Relic, Opsgenie, Graylog and Grafana. Credentials are stored in macOS Keychain. Requests require HTTPS, retain certificate validation, and reject redirects.
- Outbound now uses the same grouped settings layout as the other tabs and displays active TCP sessions under each proxy, with explicit empty and unavailable states.
- Advanced settings now explain macOS Automation, Notifications, and Files and Folders permissions. Accessibility and Screen Recording are not required by current features.

All ten DevOps adapters have fixture coverage; GitHub Actions was also tested against a live public workflow. Other providers require your configuration and authenticated validation. Legacy provider API versions may display Unavailable. This release monitors status and links to providers; it does not implement full issue or pull-request management. Barklarm imports are independent copies, not a live synchronization with its desktop app.

All bundled executables are Universal2. Existing standalone terminal sandbox and SSH authentication restrictions remain: workspace-only filesystem access, no terminal networking, option-free Ed25519 authorized_keys, and local approval for agent terminal control. SPIFFE/SPIRE remains deferred. Browser history is filesystem-protected, not encrypted by the app.

Use Check for Updates to install and relaunch. Updating ends active terminals. Legacy InfraProxy.app and bundle identifiers remain for update compatibility.

Known update quirk: if Tailscale discovery is unavailable immediately after Sparkle relaunch, quit and reopen infravibe normally. This workaround was verified previously; the underlying issue remains under investigation.
