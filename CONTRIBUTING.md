# Contributing to infravibe

Contributions through issues and pull requests are welcome. For substantial changes, open an issue first to discuss the problem and scope. Small fixes can go directly to a pull request. Maintainers review contributions as time permits; there is no guaranteed response time.

## Development setup

Use macOS 15.5 or later, Xcode Command Line Tools with Swift and the macOS SDK, Git, Python 3, and Node.js/npm. Provider CLIs (Teleport, Tailscale, gcloud, cloudflared, ngrok) are optional unless you are testing that integration. Never use production credentials or infrastructure for automated tests.

```sh
git clone https://github.com/netsecdevio/infravibe.git
cd infravibe
bash build.sh
open InfraProxy.app
```

The build downloads pinned Sparkle and npm dependencies and produces a Universal2 application. Ordinary development builds do not require signing credentials or notarization. Signing keys and release credentials belong only to the maintainers; do not request or commit them.

## Validation

From the repository root:

```sh
bash Tests/run.sh
node --check Web/app.js
bash build.sh
python3 Tests/browser-integration.py
bash scripts/verify-architectures.sh InfraProxy.app
git diff --check
```

The browser integration suite starts a temporary loopback service and test shells. Review its prerequisites and keep real tunnels disabled. Test both Intel and Apple Silicon when possible; report the architecture and macOS version you actually tested. UI changes should include screenshots and a description of the click paths tested. Unit tests or a successful build do not prove a provider connection works end to end.

## Pull requests

Fork the repository, create a branch, and keep changes focused. Describe the problem, behavior after the change, validation, and limitations. Add regression tests for meaningful behavior changes and update relevant documentation. Preserve license notices and attribution for dependencies. Do not include generated apps, dependencies, credentials, terminal transcripts, or private hostnames.

Security-sensitive changes require particular care: enforce authorization in code, validate request origins and resource ownership, bound inputs and retained output, and document trust boundaries. Do not represent shell access as sandboxed unless isolation is actually enforced and tested.

The public product is infravibe. Legacy `InfraProxy` executable names, bundle IDs, configuration paths, release filenames, and updater signing identities remain compatibility interfaces. Do not rename them as a cosmetic cleanup without an explicit migration plan.

## Releases

Maintainers publish signed and notarized releases using `scripts/package-release.sh` and validate them with `Tests/verify-release.sh`. Contribution CI uses unsigned builds and does not have release secrets. Changes to release assets, the appcast, or Homebrew checksums must match the actual published artifact.

By contributing, you agree that your contribution is licensed under the repository's existing [license](LICENSE).
