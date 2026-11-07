2110 Viewer – Installation
==========================

1. Drag “2110 Viewer” onto the “Applications” shortcut.
2. Close the window and eject the disk image.
3. Open “2110 Viewer” from your Applications folder.

That is all. GStreamer and all other components are included in the app.

If macOS says the app cannot be verified when you first open it
----------------------------------------------------------------
This happens as long as the app is not signed with an Apple Developer ID
certificate and notarized by Apple (see the project documentation).

  macOS 15 or later:
    1. Close the message with “Done”.
    2. Open System Settings › Privacy & Security.
    3. At the bottom, next to “2110 Viewer was blocked …”, click “Open Anyway”
       and confirm with your password or Touch ID.
  macOS 14:
    In the Applications folder, Control-click the app, choose “Open” and
    confirm “Open” once more.

This is only needed the first time.

What macOS may ask on first launch
----------------------------------
- “Allow 2110 Viewer to find devices on local networks?” Please allow this.
  Without it the app finds no devices and receives no streams.
- If the firewall is on, macOS asks about incoming connections. Please allow
  this as well, for the app and for the helper “gst-ptp-helper”.

More help is in the app’s Help menu under “Getting Started and Permissions”.
