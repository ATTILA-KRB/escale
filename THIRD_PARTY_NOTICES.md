# Third-party notices

Escale is released under the [GNU General Public License v3.0](LICENSE). It links or bundles the components below.
All of them use licenses that are compatible with the GPLv3; their copyright notices and license texts must be kept
when you redistribute Escale in source or binary form.

## Linked into the app (Swift Package Manager, versions pinned in `project.yml`)

| Component | Version | License | Notes |
|---|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | 1.99.3 | MIT | Terminal engine. Copyright Miguel de Icaza and the xterm.js, SourceLair and Christopher Jeffrey contributors listed in its `LICENSE`. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 | MIT | Update framework. Its `LICENSE` also covers bundled code: bsdiff (BSD-2-Clause), sais (MIT), orlp/ed25519 (zlib-style) and SUSignatureVerifier (BSD). |
| [swift-png](https://github.com/tayloraswift/swift-png) | 4.5.2 | Apache-2.0 | Transitive dependency of SwiftTerm. |
| [h](https://github.com/rarestype/h) | 1.0.1 | Apache-2.0 | Transitive dependency of swift-png. |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser) | 1.8.2 | Apache-2.0 | Resolved with SwiftTerm (build tooling). |

Apache-2.0 code can be combined with GPLv3 code (one-way compatibility: the combined work is distributed under GPLv3).

## Bundled in the app: built-in X11 server (`Contents/Helpers/EscaleX11.app`)

`scripts/x11-bundle.sh` extracts the X server and a few tools from the official
[XQuartz 2.8.6](https://github.com/XQuartz/XQuartz/releases/tag/XQuartz-2.8.6) installer (SHA-256 pinned in the script).
Nothing from XQuartz is stored in this repository; it is downloaded at build time.

- XQuartz is a collection of software under OSI-approved licenses (MIT/X11, BSD, APSL-2.0, GPL-2.0, LGPL-2.x), see the
  `XQuartz-LICENSE.txt` copied into the helper's `Resources`.
- **quartz-wm**: Apple Public Source License 2.0 (compatible with GPLv3 per the FSF). The license text is
  `scripts/x11-licenses/quartz-wm-APSL-2.0.txt`; source: <https://github.com/XQuartz/quartz-wm> (tag of XQuartz 2.8.6).
  Only library paths of the binary are modified (`install_name_tool`).
- X.Org libraries (libX11, libxcb, libXfont2, pixman, ...) are MIT/X11-style; FreeType is under the FreeType License
  (FTL) or GPLv2, which is compatible with GPLv3 under the FTL option.
- Source for every X.Org component is available from <https://gitlab.freedesktop.org/xorg> and
  <https://github.com/XQuartz>.

## Not shipped

- `spikes/freerdp/` contains build scripts for an abandoned experiment with [FreeRDP](https://github.com/FreeRDP/FreeRDP)
  (Apache-2.0). Nothing from it is in the app.
- The website in `web/` uses Astro, Tailwind CSS and other npm packages (mostly MIT); they are not part of the app.
