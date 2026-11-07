#!/usr/bin/env python3
"""Kopiert die benötigten GStreamer-Plugins samt aller abhängigen Bibliotheken
in das App-Bundle (Contents/Frameworks, Contents/PlugIns, Contents/Helpers). Nur LGPL-/BSD-/MIT-lizenzierte
Bestandteile; GPL-Plugins werden nicht verwendet.

Aufruf:
  bundle_gstreamer.py --prefix vendor/gstreamer --dest "App.app/Contents/Frameworks/GStreamer" \
                      --binary "App.app/Contents/MacOS/ST2110Viewer" [--otool otool]
"""
import argparse
import os
import shutil
import subprocess
import sys

PLUGINS = [
    "coreelements",      # queue, identity, capsfilter, fakesink (core, LGPL)
    "udp",               # udpsrc (good, LGPL)
    "rtp",               # rtpvrawdepay, rtpL24depay, rtpL16depay (good, LGPL)
    "app",               # appsink (base, LGPL)
    "audioconvert",      # base, LGPL
    "audioresample",     # base, LGPL
    "volume",            # base, LGPL
    "videotestsrc",      # Demo-Modus (base, LGPL)
    "audiotestsrc",      # Demo-Modus (base, LGPL)
    "videoconvertscale", # Demo-Modus (base, LGPL)
    "osxaudio",          # CoreAudio-Ausgabe (good, LGPL)
]
HELPERS = ["gst-plugin-scanner", "gst-ptp-helper"]
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def deps(otool, path):
    out = subprocess.run(otool + ["-L", path], check=True, capture_output=True, text=True).stdout
    ident = subprocess.run(otool + ["-D", path], check=True, capture_output=True, text=True).stdout.splitlines()
    own = ident[-1].strip() if len(ident) > 1 else None
    result = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line or line.endswith(":"):
            continue
        name = line.split(" (")[0]
        if name != own:
            result.append(name)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--dest", required=True, help="Ziel für Bibliotheken (Contents/Frameworks)")
    ap.add_argument("--plugin-dest", help="Ziel für Plugins (Contents/PlugIns)")
    ap.add_argument("--binary", action="append", default=[])
    ap.add_argument("--otool", default="otool")
    ap.add_argument("--helpers-dest", help="Ziel für ausführbare Hilfsprogramme (Contents/Helpers)")
    ap.add_argument("--manifest")
    a = ap.parse_args()
    otool = a.otool.split()
    if "llvm-otool" in a.otool and "-arch" not in a.otool:
        otool += ["-arch", "arm64"]

    lib_src = os.path.join(a.prefix, "lib")
    # Apple-Konvention: keine Unterverzeichnisse in Frameworks/PlugIns, sonst
    # hält codesign sie für (ungültige) Bundles.
    lib_dst = a.dest
    plug_dst = a.plugin_dest or os.path.join(a.dest, "gstreamer-1.0")
    # Ausführbare Hilfsprogramme gehören für codesign nach Contents/Helpers,
    # nicht unter Contents/Frameworks.
    exec_dst = a.helpers_dest or os.path.join(a.dest, "libexec", "gstreamer-1.0")
    for d in (lib_dst, plug_dst, exec_dst):
        os.makedirs(d, exist_ok=True)

    todo = []
    copied = {}
    for p in PLUGINS:
        src = os.path.join(lib_src, "gstreamer-1.0", f"libgst{p}.dylib")
        if not os.path.exists(src):
            sys.exit(f"Plugin fehlt: {src}")
        dst = os.path.join(plug_dst, os.path.basename(src))
        shutil.copy2(src, dst, follow_symlinks=True)
        todo.append(dst)
    for h in HELPERS:
        src = os.path.join(a.prefix, "libexec", "gstreamer-1.0", h)
        if not os.path.exists(src):
            sys.exit(f"Hilfsprogramm fehlt: {src}")
        dst = os.path.join(exec_dst, h)
        shutil.copy2(src, dst, follow_symlinks=True)
        os.chmod(dst, 0o755)
        todo.append(dst)
    todo += a.binary

    unresolved = []
    while todo:
        f = todo.pop()
        for d in deps(otool, f):
            if d.startswith(SYSTEM_PREFIXES):
                continue
            if d.startswith("@rpath/"):
                name = d[len("@rpath/"):]
            elif d.startswith("@loader_path/") or d.startswith("@executable_path/"):
                name = os.path.basename(d)
            else:
                name = os.path.basename(d)
            if name.startswith("GStreamer.framework") or name in copied:
                continue
            src = os.path.join(lib_src, name)
            if not os.path.exists(src):
                unresolved.append(f"{d} (benötigt von {os.path.basename(f)})")
                continue
            dst = os.path.join(lib_dst, name)
            shutil.copy2(src, dst, follow_symlinks=True)
            os.chmod(dst, 0o755)
            copied[name] = dst
            todo.append(dst)

    if unresolved:
        sys.exit("Nicht auflösbare Abhängigkeiten:\n  " + "\n  ".join(sorted(set(unresolved))))
    files = sorted(list(copied) + [f"gstreamer-1.0/libgst{p}.dylib" for p in PLUGINS] + HELPERS)
    if a.manifest:
        with open(a.manifest, "w") as m:
            m.write("\n".join(files) + "\n")
    total = 0
    for d in {lib_dst, plug_dst, exec_dst}:
        for root, _, fs in os.walk(d):
            for x in fs:
                total += os.path.getsize(os.path.join(root, x))
    print(f"{len(copied)} Bibliotheken, {len(PLUGINS)} Plugins, {len(HELPERS)} Hilfsprogramme gebündelt ({total / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
