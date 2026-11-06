# Mitgelieferte Drittanbieter-Software

Die App bettet ausgewählte Bestandteile von **GStreamer 1.28.8** (offizielle
macOS-Pakete, https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/) als
dynamische Bibliotheken ein. Es werden **keine GPL-Plugins** verwendet.

| Bestandteil | Dateien | Lizenz | Quelltext |
|---|---|---|---|
| GStreamer (core, base, good: coreelements, udp, rtp, app, audioconvert, audioresample, volume, videotestsrc, audiotestsrc, videoconvertscale, osxaudio; gst-plugin-scanner, gst-ptp-helper) | `libgst*.dylib`, `libexec/gstreamer-1.0/*` | LGPL-2.1-or-later (`LGPL-2.1-GStreamer.txt`) | https://gstreamer.freedesktop.org/src/ (Version 1.28.8) |
| GLib / GObject / GIO / GModule | `libglib-2.0`, `libgobject-2.0`, `libgio-2.0`, `libgmodule-2.0` | LGPL-2.1-or-later | https://download.gnome.org/sources/glib/ |
| gettext-runtime (libintl) | `libintl.8.dylib` | LGPL-2.1-or-later | https://ftp.gnu.org/gnu/gettext/ |
| ORC | `liborc-0.4` | BSD-2-Clause (`orc-BSD.txt`) | https://gitlab.freedesktop.org/gstreamer/orc |
| libffi | `libffi.7.dylib` | MIT (`libffi-MIT.txt`) | https://github.com/libffi/libffi |
| PCRE2 | `libpcre2-8` | BSD-3-Clause mit Ausnahme (`pcre2-BSD.txt`) | https://github.com/PCRE2Project/pcre2 |
| zlib | `libz.1.dylib` | zlib (`zlib.txt`) | https://github.com/madler/zlib |

Die genauen Versionen der Abhängigkeiten entsprechen dem GStreamer-Build
„cerbero 1.28“ (https://gitlab.freedesktop.org/gstreamer/cerbero, Zweig 1.28).

**LGPL-Hinweis:** Die LGPL-Bibliotheken liegen unverändert und dynamisch gelinkt
unter `ST 2110 Monitor.app/Contents/Frameworks/GStreamer/lib`. Sie können durch
eigene, kompatible Builds ersetzt werden (danach App neu signieren, z. B. ad hoc
mit `codesign --force --deep --sign - "ST 2110 Monitor.app"`). Auf Anfrage stellen
wir die verwendeten Quelltexte bereit; sie sind außerdem unter den genannten
Adressen öffentlich verfügbar.

Liste aller eingebetteten Dateien: `Contents/Resources/gstreamer-files.txt`.
