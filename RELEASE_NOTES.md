# InfraProxy 2.5.0

Google Cloud setup now discovers the installed CLI, saved accounts, accessible projects, and resources automatically. The Google Cloud tab replaces manual project and executable text fields with populated selectors.

- **Sign in / Add account** starts Google's browser authorization flow and refreshes accounts, projects, and resources when it finishes.
- **Reauthenticate** renews the selected account through a fresh browser flow. Google or the configured organization identity provider controls which passkeys, hardware security keys, passwords, and verification methods are available. InfraProxy does not collect those credentials.
- **Cancel sign-in** cancels an unfinished login. Login output containing authorization URLs or codes is not displayed or logged by InfraProxy.
- Browse VM instances, Storage buckets, Cloud SQL instances, Kubernetes clusters, Cloud Run services, and VPC networks. Cloud Console links open the selected project and account for resource management, project overview, logs, IAM, and enabled APIs.
- VM power controls and IAP SSH explicitly use the selected account, project, and zone. Switching accounts or projects clears old resource results. Other resource categories are read-only.
- Google Cloud CLI installation is detected automatically. If it is missing, the app offers the official install page and a file picker for an existing installation. Credentials remain managed by the CLI; the app remembers only selections and the executable path.
- Existing Teleport expiry monitoring and per-port TCP session statistics are retained.

## Usage

Open **Connection Dashboard & GCP… → Google Cloud**. Existing gcloud accounts and projects populate automatically. For a new account, choose **Sign in / Add account**, complete the browser flow, and select a discovered project. For an expired login, choose **Reauthenticate**. Refresh tokens are otherwise managed by gcloud.

The CLI is still required. Account and project selection in InfraProxy does not change the active gcloud account or project for other tools. Existing organization login configuration is honored. Hardware-key and passkey availability depends on the Google/organization account and browser configuration. Resource visibility depends on IAM access and enabled APIs; the app reports discovery errors instead of displaying an empty success result. No service APIs are explicitly enabled by InfraProxy.

## Validation

- Native build and regression tests cover discovery, account/project scoping, account switching, login completion/failure, authorization-output suppression, missing CLI, malformed data, resource parsing, command cancellation, and separate stdout/stderr handling.
- Live read-only account/project discovery and all six resource-list commands verified. Populated VM and Cloud Run views inspected in the native UI.
- Real passkey/security-key authentication and production VM start/stop were not performed during validation; authentication lifecycle and operation arguments were tested with a simulated CLI.
