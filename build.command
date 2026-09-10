#!/bin/zsh
set -e
cd "${0:A:h}"
mkdir -p 'Agent Island.app/Contents/MacOS' 'Agent Island.app/Contents/Resources'
xcrun swiftc Sources/main.swift -o 'Agent Island.app/Contents/MacOS/AgentIsland' -framework Cocoa -framework SwiftUI -framework ApplicationServices -framework ServiceManagement -target arm64-apple-macosx14.0 -O
cp Resources/monitor.py Resources/*.svg 'Agent Island.app/Contents/Resources/'
cat > 'Agent Island.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentIsland</string>
<key>CFBundleIdentifier</key><string>local.agentisland.mac</string>
<key>CFBundleName</key><string>Agent Island</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - 'Agent Island.app'
