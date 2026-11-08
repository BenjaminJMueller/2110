# Build, packaging, signing and distribution

[Deutsch](../04-Build-und-Verteilung.md)

## For end users

End users only download the **DMG**, drag the app to Applications and launch it.
GStreamer and all libraries live inside the app (`Contents/Frameworks`, `Contents/PlugIns`, `Contents/Helpers`). Nothing is installed into system folders.

Requirements: Mac with Apple silicon (M1 or later, target M4), **macOS 14 Sonoma or later**.
Liquid Glass interface from macOS 26; on macOS 14/15 the same controls appear with native materials.

## Building the DMG without your own Mac: GitHub Actions

Every push starts the workflow `.github/workflows/macos.yml`. It:

1. builds and tests the receive core on Linux (unit, loopback and self-test),
2. downloads the official GStreamer packages on a macOS 26 runner and checks their SHA-256 checksums,
3. runs the Swift unit tests,
4. builds the app, embeds GStreamer, signs it ad hoc and runs the **self-test of the finished app** (`--selftest`: demo, loopback reception, lip sync, PTP helper),
5. creates the DMG and provides it as the artifact “2110-Viewer-dmg” (Actions › run › Artifacts),
6. takes screenshots in German and English.

Note: macOS minutes count ten times against the Actions quota for private repositories. For public repositories they are free.

A release with the DMG is created via *Actions › Build und Tests › Run workflow* with the “Release” option, or by pushing a tag `v<version>`.

## Building on your own Mac (reproducible)

Requirements: Apple silicon, macOS 15 or later, **Xcode 26** (from the App Store; includes Swift 6.2 and the macOS 26 SDK). With an older Xcode the app builds without Liquid Glass.

```bash
git clone <repository> && cd 2110
./scripts/build-app.sh
# Result: dist/2110 Viewer.app and dist/2110-Viewer-1.0.0.dmg
```

What the script does:

| Step | Script |
|---|---|
| Download GStreamer 1.28.8, verify checksums, unpack to `vendor/gstreamer` without installing (`pkgutil --expand-full`) | `scripts/fetch-gstreamer.sh` |
| Compile (Swift package, release, arm64) | `swift build` |
| Bundle, Info.plist, icon (`packaging/icon/AppIcon.svg` → PNG → icns) | `scripts/build-app.sh` |
| Copy the required plugins and their dependencies (list in `bundle_gstreamer.py`), thin to arm64 | `scripts/bundle_gstreamer.py` |
| Add license texts | `packaging/licenses` |
| Language files German and English from `App/Localization/en.json` | `scripts/gen-l10n.py` |
| Sign (inside out) and verify | `codesign` |
| Self-test of the finished bundle | `--selftest` |
| License audit of app and DMG | `scripts/audit-bundle.py` |
| DMG with an “Applications” shortcut and quick guide (German, English) | `scripts/make-dmg.sh` |
| Source code of the embedded libraries | `scripts/fetch-third-party-sources.sh` |

Developing in Xcode: open `Package.swift` with Xcode. Run `./scripts/fetch-gstreamer.sh` once beforehand and set the environment variable `GSTREAMER_PREFIX=<repo>/vendor/gstreamer` in the scheme.

Receive core without the app (Linux, or macOS with pkg-config):

```bash
make -C core && make -C core test     # unit and loopback tests
core/build/st2110-probe --help         # command-line receiver
```

## Signing and notarization: current status

**There is no Apple Developer account.** Consequences:

* The app is **signed ad hoc**. It runs on Apple silicon, but Gatekeeper blocks it on first launch if it was downloaded from the internet.
* One-time approval: System Settings › Privacy & Security › “Open Anyway” (macOS 15+); on macOS 14 Control-click › Open. This is also explained in “Read me first.txt” on the DMG.
* If the DMG is distributed via USB stick or network drive instead of a browser, the prompt usually does not appear because no quarantine attribute is set.
* After every update macOS asks again about Local Network and possibly the firewall, because the ad hoc signature changes.

**Missing for regular distribution:**

1. Membership in the **Apple Developer Program** (as an organization, e.g. a university; requires a D-U-N-S number; 99 USD/year),
2. a **“Developer ID Application”** certificate in the build Mac’s keychain,
3. an **app-specific password** or API key for `notarytool`.

Then this is enough:

```bash
xcrun notarytool store-credentials st2110-notary --apple-id … --team-id … --password …
SIGN_IDENTITY="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=st2110-notary ./scripts/build-app.sh
```

The script then signs with hardened runtime and a timestamp, submits the DMG for notarization and staples the ticket. For GitHub Actions the certificate and credentials have to be stored as encrypted secrets; the workflow is prepared for this but not set up.

## Updates (Sparkle)

The app checks for new versions once a day (can be turned off under *Advanced › Info*) and installs them on request. [Sparkle](https://sparkle-project.org) 2.10.1 is embedded for this (MIT).

- The version list `appcast.xml` is attached to the latest GitHub release; the app reads it via `releases/latest/download/appcast.xml`.
- Every DMG is signed with an EdDSA key (Ed25519). The app contains the public part (`packaging/sparkle-public-key.txt`) and installs only updates with a matching signature. With the ad-hoc signature, this replaces the missing Developer ID.
- The private key exists only as the repository secret `SPARKLE_PRIVATE_KEY` (*Settings › Secrets and variables › Actions*). The release run signs the DMG with it and checks that it matches the public key. Without the secret, the release is published without an update feed.
- If the private key is lost, existing installations can no longer be updated; a new key pair and one manual installation are needed. Keep a copy somewhere safe (password manager).
- Release notes in the update window: `packaging/release-notes/<version>.de.html` and `.en.html`.

## App permissions

| Permission | What for | How |
|---|---|---|
| Camera, microphone | only when sending from a camera | system prompt, reason text in Info.plist |
| Local Network (macOS 15+) | NMOS discovery (mDNS), HTTP to the devices, multicast reception | system prompt on first access, reason text in Info.plist |
| Incoming connections | only with the firewall on, for the app and `gst-ptp-helper` | system prompt |
| No sandbox | multicast on a freely chosen interface and PTP ports 319/320 are not possible in the App Sandbox | only relevant for Developer ID distribution (not the App Store) |
| Administrator rights | not needed | |
