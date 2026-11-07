#!/usr/bin/env python3
"""Lizenz- und Inhaltsprüfung für Essenz.app bzw. das gemountete DMG.

Prüft:
  1. Jede ausführbare Datei / Bibliothek ist einem bekannten Bestandteil mit
     bekannter, weiterverteilbarer Lizenz zugeordnet (Positivliste).
  2. Für jede vorkommende Lizenz liegt der Lizenztext im Bundle.
  3. LICENSE (MIT) und THIRD_PARTY_NOTICES.md liegen im Bundle.
  4. Keine GPL-/Codec-/Herstellerbestandteile (Negativliste über Dateinamen).
  5. Keine Dateien mit unbekannter Herkunft (alles außerhalb der Positivliste ist ein Fehler).

Aufruf: audit-bundle.py <Essenz.app | gemountetes DMG-Verzeichnis> [--report datei]
Rückgabe 0 = in Ordnung.
"""
import os
import re
import sys

LICENSE_FILES = {
    "MIT (Essenz)": "LICENSE",
    "LGPL-2.1-or-later": "LGPL-2.1.txt",
    "LGPL-2.0-or-later": "LGPL-2.1.txt",
    "BSD (ORC)": "orc-BSD.txt",
    "BSD-3-Clause (PCRE2)": "pcre2-BSD.txt",
    "MIT (libffi)": "libffi-MIT.txt",
    "Zlib": "zlib.txt",
}

# (Regex auf Pfad relativ zu Contents/, Bestandteil, Lizenz)
ALLOW = [
    (r"^MacOS/Essenz$", "Essenz", "MIT (Essenz)"),
    (r"^Helpers/gst-(plugin-scanner|ptp-helper)$", "GStreamer core 1.28.8", "LGPL-2.1-or-later"),
    (r"^Frameworks/libgst(reamer|base|net)-1\.0\.0\.dylib$", "GStreamer core 1.28.8", "LGPL-2.1-or-later"),
    (r"^Frameworks/libgst(app|audio|video|rtp|tag|pbutils|riff)-1\.0\.0\.dylib$", "GStreamer base 1.28.8", "LGPL-2.1-or-later"),
    (r"^PlugIns/libgst(coreelements)\.dylib$", "GStreamer core 1.28.8", "LGPL-2.1-or-later"),
    (r"^PlugIns/libgst(app|audioconvert|audioresample|volume|videotestsrc|audiotestsrc|videoconvertscale)\.dylib$", "GStreamer base 1.28.8", "LGPL-2.1-or-later"),
    (r"^PlugIns/libgst(udp|rtp|osxaudio)\.dylib$", "GStreamer good 1.28.8", "LGPL-2.1-or-later"),
    (r"^Frameworks/lib(glib|gobject|gio|gmodule)-2\.0\.0\.dylib$", "GLib 2.82.4", "LGPL-2.1-or-later"),
    (r"^Frameworks/libintl\.8\.dylib$", "proxy-libintl 0.5", "LGPL-2.0-or-later"),
    (r"^Frameworks/liborc-0\.4\.0\.dylib$", "ORC 0.4.42", "BSD (ORC)"),
    (r"^Frameworks/libffi\.7\.dylib$", "libffi 3.2.9999.5", "MIT (libffi)"),
    (r"^Frameworks/libpcre2-8\.0\.dylib$", "PCRE2 10.42", "BSD-3-Clause (PCRE2)"),
    (r"^Frameworks/libz\.1\.dylib$", "zlib 1.3.1", "Zlib"),
    # Nicht ausführbare Dateien
    (r"^Info\.plist$", "Essenz", "MIT (Essenz)"),
    (r"^PkgInfo$", "Essenz", "MIT (Essenz)"),
    (r"^_CodeSignature/CodeResources$", "Signatur", None),
    (r"^Resources/AppIcon\.icns$", "Essenz (eigenes Symbol)", "MIT (Essenz)"),
    (r"^Resources/gstreamer-files\.txt$", "Essenz", "MIT (Essenz)"),
    (r"^Resources/Licenses/[^/]+$", "Lizenztexte", None),
]

DENY = re.compile(r"(x264|x265|libav|avdec|avcodec|ffmpeg|faad|a52|mpeg2dec|dvdread|dvdsub|lame|mpg123|"
                  r"blackmagic|bmd|decklink|desktopvideo|vulkan|molten|gpl)", re.I)


def is_macho(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError:
        return False
    return magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                     b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce")


def find_app(root):
    if root.endswith(".app"):
        return root
    for name in os.listdir(root):
        if name.endswith(".app"):
            return os.path.join(root, name)
    sys.exit(f"Keine .app in {root}")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    target = sys.argv[1].rstrip("/")
    report_path = sys.argv[sys.argv.index("--report") + 1] if "--report" in sys.argv else None
    app = find_app(target)
    contents = os.path.join(app, "Contents")
    errors, rows, licenses_needed = [], [], set()

    # DMG-Ebene: nur App, Verknüpfung, Hinweistext
    if not target.endswith(".app"):
        for name in os.listdir(target):
            p = os.path.join(target, name)
            if name.endswith(".app") or name.startswith("."):
                continue
            if os.path.islink(p) and os.readlink(p) == "/Applications":
                continue
            if name in ("Bitte zuerst lesen.txt", "LICENSE.txt", "THIRD_PARTY_NOTICES.md"):
                continue
            errors.append(f"Unbekannte Datei auf dem DMG: {name}")

    for dirpath, _, files in os.walk(contents):
        for fn in files:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, contents)
            if DENY.search(rel) and not rel.startswith("Resources/Licenses/"):
                errors.append(f"Verbotener Bestandteil (Negativliste): {rel}")
            match = next(((c, l) for rx, c, l in ALLOW if re.match(rx, rel)), None)
            if match is None:
                errors.append(f"Unbekannte Datei ohne geklärte Lizenz: {rel}" + (" (Mach-O)" if is_macho(full) else ""))
                continue
            comp, lic = match
            if lic:
                licenses_needed.add(lic)
            if is_macho(full) or rel.endswith(".dylib"):
                rows.append((rel, comp, lic))

    lic_dir = os.path.join(contents, "Resources", "Licenses")
    for lic in sorted(licenses_needed):
        f = LICENSE_FILES[lic]
        if not os.path.isfile(os.path.join(lic_dir, f)):
            errors.append(f"Lizenztext fehlt für {lic}: Resources/Licenses/{f}")
    for f in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        if not os.path.isfile(os.path.join(lic_dir, f)):
            errors.append(f"Fehlt im Bundle: Resources/Licenses/{f}")

    out = ["Lizenzprüfung " + app, ""]
    out += [f"  {r:60s} {c:28s} {l}" for r, c, l in sorted(rows)]
    out += ["", f"{len(rows)} Binärdateien, Lizenzen: {', '.join(sorted(licenses_needed))}"]
    out += [("FEHLER: " + e) for e in errors]
    out.append("ERGEBNIS: " + ("bestanden" if not errors else f"{len(errors)} Fehler"))
    text = "\n".join(out)
    print(text)
    if report_path:
        with open(report_path, "w") as f:
            f.write(text + "\n")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
