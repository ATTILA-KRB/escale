# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- English interface: the app follows the system language (French or English) through a String Catalog
  (`Escale/Resources/Localizable.xcstrings`).

### Changed
- Source code published under the GNU GPL v3.0 (`LICENSE`, `THIRD_PARTY_NOTICES.md`), with English and French READMEs,
  issue forms and contributing guide.

## [1.0.0] - 2026-11-15

First public release (build 79), Developer ID signed and notarized, distributed with Sparkle updates.

### Added
- Tabbed terminal on SwiftTerm and the system OpenSSH (`ControlMaster`), split panes, detachable tabs, compact mode,
  automatic reconnection that keeps the screen, optional output highlighting.
- Session library with folders, search, quick connect (`⇧⌘K`), secrets in the macOS Keychain, bastion hosts via `ProxyJump`.
- SFTP pane that follows the terminal folder over the existing connection: drag and drop, transfer queue,
  server-to-server copy, remote file editing, shell fallback.
- Tunnel manager: local, remote and dynamic (SOCKS) forwards, IPv6, live editing, port probing.
- Multi-execution: keystroke broadcast to panes and group command execution with per-host output and exit code.
- Built-in X11 server (from XQuartz 2.8.6, no installation required).
- Telnet, serial, VNC (native RFB client) and RDP (via Windows App) sessions.
- Macros, server monitoring, import from MobaXterm, PuTTY, CSV and `~/.ssh/config`.
- Update checks through Sparkle (EdDSA-signed appcast).

[Unreleased]: https://github.com/ATTILA-KRB/escale/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ATTILA-KRB/escale/releases/tag/v1.0.0
