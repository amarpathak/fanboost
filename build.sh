#!/bin/sh
set -e
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
# Universal binaries: run on both Intel and Apple Silicon Macs.
clang -O2 -Wall -arch x86_64 -arch arm64 -o fanctl fanctl.c sensors.c smc.c -framework IOKit -framework CoreFoundation
mkdir -p FanBoost.app/Contents/MacOS build
# The app reads sensors in-process through the same C code (sensors.h is the bridge).
for arch in x86_64 arm64; do
    clang -O2 -Wall -arch $arch -mmacosx-version-min=13.0 -c sensors.c -o build/sensors-$arch.o
    clang -O2 -Wall -arch $arch -mmacosx-version-min=13.0 -c smc.c -o build/smc-$arch.o
    swiftc -O -target $arch-apple-macos13 -import-objc-header sensors.h \
        -o build/FanBoost-$arch *.swift build/sensors-$arch.o build/smc-$arch.o \
        -framework IOKit -framework CoreFoundation
done
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
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# Ad-hoc signatures (Apple Silicon refuses to run unsigned code).
codesign --force -s - fanctl
codesign --force -s - FanBoost.app
echo "built FanBoost.app and fanctl $VERSION"
