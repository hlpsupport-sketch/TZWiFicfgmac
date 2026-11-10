#!/bin/bash
# Builds dist/"Tzone Config.app" with Python and libusb bundled (no Python needed on the Mac).
set -euo pipefail
cd "$(dirname "$0")"
python -m pip install -r requirements-build.txt
pyinstaller --noconfirm --windowed --name "Tzone Config" \
  --osx-bundle-identifier au.com.hlpcontrols.tzoneconfig \
  --collect-all libusb_package --hidden-import usb.backend.libusb1 \
  tzone_app.py
ls -la "dist/Tzone Config.app/Contents/MacOS"
file "dist/Tzone Config.app/Contents/MacOS/"*
