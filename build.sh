#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="${1:-build/轻截.app}"
# Build a staging copy; installation is a separate, explicit step.
APP="${APP:A}"
if [[ "$APP" == /Applications/* || "$APP" == "$HOME/Applications/"* ]]; then
  print -u2 'Build into a staging directory before updating an installed app.'
  exit 1
fi
ARCH="${ARCH:-$(uname -m)}"
if [[ "$ARCH" != arm64 && "$ARCH" != x86_64 ]]; then
  print -u2 'ARCH must be arm64 or x86_64.'
  exit 1
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build
xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache \
  -target "${ARCH}-apple-macosx14.0" Main.swift Editor.swift TextEditing.swift SelfTest.swift \
  -o "$APP/Contents/MacOS/LightShot" -framework AppKit -framework Carbon \
  -framework ScreenCaptureKit -framework ServiceManagement -framework CoreImage
cp Info.plist "$APP/Contents/Info.plist"
xcrun swiftc -O -module-cache-path .build/module-cache MakeIcon.swift -o .build/make-icon
.build/make-icon .build/LightShot.iconset
iconutil -c icns .build/LightShot.iconset -o "$APP/Contents/Resources/LightShot.icns"
python3 sign.py "$APP"
echo "Built: $APP"
