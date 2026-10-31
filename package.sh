#!/bin/sh
# Builds dist/FanBoost-<version>.pkg, a double-click installer.
set -e
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
ID=io.github.amarpathak.fanboost
./build.sh

rm -rf build/pkgroot dist && mkdir -p build/pkgroot/Applications build/pkgroot/usr/local/bin dist
cp -R FanBoost.app build/pkgroot/Applications/
cp fanctl packaging/fanboost-uninstall build/pkgroot/usr/local/bin/
# Strip extended attributes so no ._ AppleDouble files end up in the payload.
xattr -cr build/pkgroot
export COPYFILE_DISABLE=1

# Pin the app to /Applications. Otherwise Installer may "upgrade" any other copy of
# FanBoost.app it finds on disk (like this build folder) instead.
pkgbuild --analyze --root build/pkgroot build/components.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO build/components.plist

pkgbuild --root build/pkgroot --component-plist build/components.plist \
    --scripts packaging/scripts --identifier "$ID" --version "$VERSION" \
    --install-location / build/fanboost-component.pkg
sed "s/VERSION/$VERSION/" packaging/distribution.xml > build/distribution.xml
productbuild --distribution build/distribution.xml --resources packaging/resources \
    --package-path build "dist/FanBoost-$VERSION.pkg"
echo "built dist/FanBoost-$VERSION.pkg"
