#!/bin/sh
set -e
cd "$(dirname "$0")"
clang -O2 -Wall -o fanctl fanctl.c smc.c -framework IOKit
mkdir -p FanBoost.app/Contents/MacOS
swiftc -O -o FanBoost.app/Contents/MacOS/FanBoost FanBoost.swift
cat > FanBoost.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.fanboost</string>
  <key>CFBundleName</key><string>FanBoost</string>
  <key>CFBundleExecutable</key><string>FanBoost</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
echo "built FanBoost.app and fanctl"
