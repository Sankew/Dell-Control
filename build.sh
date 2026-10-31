#!/bin/zsh
# Builds "Dell Control.app" with the Command Line Tools (no Xcode) and installs it to ~/Applications.
set -euo pipefail
cd "${0:A:h}"
app="build/Dell Control.app"
rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/"
swiftc -O -swift-version 6 -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault -target arm64-apple-macos15 Sources/*.swift -o "$app/Contents/MacOS/DellControl" 2>&1 | grep -v '^.*warning' || true
[[ -x "$app/Contents/MacOS/DellControl" ]] || { echo "build failed"; exit 1; }
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.sankew.dellcontrol</string>
  <key>CFBundleName</key><string>Dell Control</string>
  <key>CFBundleExecutable</key><string>DellControl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Ad-hoc signature: fine for a personal app that needs no special permissions.
codesign --force --sign - "$app"
"$app/Contents/MacOS/DellControl" selftest
mkdir -p ~/Applications
rm -rf ~/Applications/"Dell Control.app"
cp -R "$app" ~/Applications/
echo "installed ~/Applications/Dell Control.app"
