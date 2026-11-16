# Contributing to Escale

Thanks for your interest. Escale is a native macOS SSH client released under the [GPLv3](LICENSE); by submitting a
contribution you agree to license it under the same terms.

## Before you start

- **Questions, ideas, "is this a bug?"**: open a [Discussion](https://github.com/ATTILA-KRB/escale/discussions).
- **Bugs and feature requests**: use the issue forms. Never paste passwords, private keys or real server details.
- **Security issues**: use a [private advisory](https://github.com/ATTILA-KRB/escale/security/advisories/new), not a public issue.
- For anything bigger than a small fix, discuss it first so effort is not wasted.

## Read first

- [AGENTS.md](AGENTS.md): structure, commands and the **invariants** (no secret on disk or in logs, never write to `~/.ssh`,
  never kill `ssh` processes by broad pattern, a changed host key is always refused, ...). A change that breaks one will not be merged.
- [docs/PLAN.md](docs/PLAN.md): design decisions and why SwiftTerm + system OpenSSH with `ControlMaster`.

## Development setup

Requirements: macOS 15+, Xcode with Swift 6 support, `brew install xcodegen`.

```sh
git clone https://github.com/<you>/escale.git && cd escale
scripts/test.sh                 # core tests + Debug build; run before every commit
xcodegen generate && open Escale.xcodeproj
```

- `Packages/EscaleCore` holds the UI-free logic and is tested with `swift test`. `Escale/` is the SwiftUI/AppKit app.
  SwiftTerm types stay inside `Escale/Terminal/`.
- Changes under `Escale/` should also run the matching `scripts/selftest-<module>.sh` (they run the app against a local
  `sshd`, one at a time). See AGENTS.md.
- `Escale.xcodeproj` is generated from `project.yml`: edit `project.yml`, never the project.
- The first build downloads the XQuartz installer used for the embedded X11 server (SHA-256 pinned).

## Conventions

- Swift 6 with strict concurrency.
- Existing code comments are in French; French or English is fine for new ones.
- Search with `rg`.
- Test hosts in fixtures, docs and screenshots must be fictional (`example.com`, `10.x`, documentation ranges). Do not
  commit screenshots of real servers.

## Pull requests

1. Fork, then branch from `main`: one topic per pull request.
2. Keep commits focused. Subjects are short, imperative and **without accents** (for example `Fix tunnel probe on IPv6`).
3. Run `scripts/test.sh` and the relevant self-tests; say what you ran in the PR description.
4. Fill in the pull request template. Maintainers merge with a merge commit.

## Releases

Maintainers only: [docs/RELEASE.md](docs/RELEASE.md) (written in French). The update feed and signing keys are not part
of the repository. User-visible changes go in [CHANGELOG.md](CHANGELOG.md) under "Unreleased".
