# Source code of the embedded libraries (LGPL)

[Deutsch](../LGPL-Quellen.md)

2110 Viewer.app contains GStreamer and other libraries under LGPL-2.1-or-later
(as well as BSD, MIT, zlib). The complete list with versions is in
[`THIRD_PARTY_NOTICES.md`](../../THIRD_PARTY_NOTICES.md).

## How the project meets the LGPL

| Obligation | Implementation |
|---|---|
| Notice of the library and its license | `THIRD_PARTY_NOTICES.md` and license texts in `2110 Viewer.app/Contents/Resources/Licenses/`; also on the DMG |
| Provide the source code (§ 6) | Every release ships `2110-Viewer-<version>-third-party-sources.tar.gz` next to the DMG: all upstream archives (checksums from the cerbero recipes) and **cerbero 1.28.8** with all patches and build recipes. Created by `scripts/fetch-third-party-sources.sh` in CI. |
| Allow replacing the library | Dynamically linked, unmodified individual files in `Contents/Frameworks` and `Contents/PlugIns`. After replacing a file, re-sign the app (`codesign --force --deep --sign - "2110 Viewer.app"`). |
| No restriction through the main program’s license | 2110 Viewer is MIT licensed and does not restrict modification, reverse engineering for debugging or replacing the LGPL libraries. |

## Rebuilding

```bash
tar xzf 2110-Viewer-1.0.0-third-party-sources.tar.gz
cd 2110-viewer-third-party-sources
shasum -a 256 -c SHA256SUMS
tar xzf cerbero-1.28.8.tar.gz && cd cerbero-1.28.8
./cerbero-uninstalled -c config/osx-universal.cbc package gstreamer-1.0
```

2110 Viewer uses only the files selected by `scripts/bundle_gstreamer.py`.

## Checking every DMG

`scripts/audit-bundle.py` runs on every build against the finished app **and** the mounted DMG:

* every binary must be on an allowlist that maps it to a component and a license,
* the license text for every license must be in the bundle,
* file names of GPL plugins, codecs (x264, libav, …) and manufacturer components (Blackmagic, DeckLink, …) abort the build,
* unknown files abort the build.

In addition, `--selftest` checks the license of every loaded GStreamer plugin (only LGPL, BSD and MIT are allowed). The reports (`license-audit-app.txt`, `license-audit-dmg.txt`) are included with the CI artifacts and every release.
