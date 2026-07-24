# Contributing to NOOP

NOOP is an iPhone-only, local-first companion app for supported WHOOP straps. It connects over Bluetooth, stores data on-device, and computes its own health and workout metrics. There are no Android, macOS app, or watchOS targets in the current repository.

Read the full [contributing guide](docs/CONTRIBUTING.md) before opening a non-trivial pull request. NOOP is not affiliated with WHOOP and is not a medical device; see [DISCLAIMER.md](DISCLAIMER.md).

## Quick start

The Xcode project is generated from `project.yml`:

```bash
brew install xcodegen
xcodegen generate
xcodebuild \
  -scheme NOOPiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

For fast package-level feedback:

```bash
swift test --package-path Packages/WhoopProtocol
```

Substitute the package you changed. Reusable packages intentionally retain macOS declarations so SwiftPM tests can run on a Mac; those declarations do not define a macOS application.

## Pull requests

1. Keep one concern per PR where practical.
2. Regenerate the project after changing `project.yml` or source membership.
3. Add deterministic tests for analytics, persistence, and protocol changes.
4. For BLE changes, report the exact physical strap and iPhone coverage. A green build is not hardware proof.
5. For UI changes, use `StrandDesign` tokens and include iPhone screenshot QA.
6. Never commit real health exports, unsanitized captures, databases, signing credentials, API keys, or generated build products.

GitHub Actions builds the iPhone app and tests the reusable Swift packages. Fix failures rather than weakening the checks.

## Issues and conduct

- Use [.github/ISSUE_TEMPLATE](.github/ISSUE_TEMPLATE) for bugs and feature requests.
- Follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
- By contributing, you license your work under [LICENSE](LICENSE).
