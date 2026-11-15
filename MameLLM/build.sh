#!/bin/sh
# Builds MameLLM for macOS (Apple Silicon + Intel) into dist/.
# Needs only Go 1.21+ (brew install go). Cross-compiles from any OS.
set -eu
cd "$(dirname "$0")"
rm -rf dist
for arch in arm64 amd64; do
  app="dist/MameLLM-macos-$arch/MameLLM.app"
  mkdir -p "$app/Contents/MacOS"
  CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags "-s -w" -o "$app/Contents/MacOS/mamellm" .
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>MameLLM</string>
  <key>CFBundleIdentifier</key><string>local.mamellm</string>
  <key>CFBundleExecutable</key><string>mamellm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
  echo "built $app"
done
