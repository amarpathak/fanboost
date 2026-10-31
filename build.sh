#!/bin/sh
set -e
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
# Universal binaries: run on both Intel and Apple Silicon Macs.
clang -O2 -Wall -arch x86_64 -arch arm64 -o fanctl fanctl.c smc.c -framework IOKit -framework CoreFoundation
mkdir -p FanBoost.app/Contents/MacOS build
swiftc -O -target x86_64-apple-macos11 -o build/FanBoost-x86_64 FanBoost.swift
swiftc -O -target arm64-apple-macos11 -o build/FanBoost-arm64 FanBoost.swift
lipo -create build/FanBoost-x86_64 build/FanBoost-arm64 -output FanBoost.app/Contents/MacOS/FanBoost
cat > FanBoost.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.amarpathak.fanboost</string>
  <key>CFBundleName</key><string>FanBoost</string>
  <key>CFBundleExecutable</key><string>FanBoost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc signatures (Apple Silicon refuses to run unsigned code).
codesign --force -s - fanctl
codesign --force -s - FanBoost.app
echo "built FanBoost.app and fanctl $VERSION"
