# InfraProxy 2.4.0

- Adds a menu bar countdown to the configured Teleport proxy credential expiry, including explicit expired and unavailable states.
- Adds **Connection Dashboard & GCP…** with live local listeners and accepted TCP sessions grouped by configured connection. Refreshes every five seconds, with a one-second countdown.
- Adds Google Cloud project and CLI-path settings, instance status, start/stop operations, and SSH connections through IAP in Terminal. Stop requires confirmation naming the instance, project, and zone. VM status refreshes every 30 seconds while the dashboard is open.
- Cloud operations use the existing gcloud identity and explicit project/zone. No cloud credentials are stored by InfraProxy.

## Requirements and scope

Install and authenticate the Google Cloud CLI (`gcloud auth login`), then enter the project ID and absolute CLI path in the Google Cloud tab. Compute Engine permissions are required for listing and power operations; SSH through IAP additionally requires the appropriate IAP/SSH permissions and firewall rules. macOS may ask to allow InfraProxy to control Terminal.

The timer reflects Teleport certificate validity, not a guarantee of when an established tunnel will disconnect. Local TCP sessions are not cluster-wide Teleport sessions; HTTP-to-SOCKS forwarding appears on both listeners. Port-based observations can include another process occupying a configured port. GCP SSH windows are owned by Terminal and are not counted as local proxy sessions.

## Validation

- Native macOS build and targeted Swift tests: profile matching, fractional expiry, missing and expired credentials, countdown arithmetic, shell quoting, subprocess output draining, timeout, executable failure, and GCP JSON decoding.
- Live Teleport status parsing and read-only GCP instance listing checked locally.
- VM start/stop and interactive IAP SSH were not exercised against production workloads.
