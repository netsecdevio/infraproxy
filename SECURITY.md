# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/netsecdevio/infravibe/security/advisories/new). Do not publish exploit details or secrets in ordinary issues. Include affected versions, prerequisites, reproduction steps, impact, and any suggested mitigation. Redact tokens, personal data, and private infrastructure addresses.

Maintainers will triage reports as availability permits. This project does not promise a response-time SLA or a bounty. Coordinate public disclosure with the maintainers after a fix or mitigation is available.

## Supported versions and boundaries

Security fixes target the latest stable release. Development branches may contain incomplete protections and are not a substitute for a supported release.

Remote terminal access is security-sensitive. Authentication alone does not provide operating-system isolation. Unless a specific release documents and verifies a sandbox, terminal processes inherit the host user's permissions. Keep remote access disabled when it is not needed, and only trust clients allowed to access that account. Never share browser login keys, agent tokens, private keys, or unredacted terminal output in reports.
