#!/bin/sh
# From-source install: builds FanBoost and installs it the same way the .pkg does.
# Run with: sudo ./install.sh   (or build dist/*.pkg with ./package.sh and double-click it)
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run: sudo $0"; exit 1; }
USER_NAME="${SUDO_USER:?run via sudo}"
sudo -u "$USER_NAME" ./build.sh
packaging/scripts/preinstall
mkdir -p /usr/local/bin
install -o root -g wheel -m 755 fanctl /usr/local/bin/fanctl
install -o root -g wheel -m 755 packaging/fanboost-uninstall /usr/local/bin/fanboost-uninstall
rm -rf /Applications/FanBoost.app
cp -R FanBoost.app /Applications/
FANBOOST_USER="$USER_NAME" packaging/scripts/postinstall
echo "installed. FanBoost is in your menu bar and starts at login."
