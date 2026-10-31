#!/bin/sh
set -e
[ "$(id -u)" = 0 ] || { echo "run: sudo $0"; exit 1; }
if [ -n "$SUDO_USER" ]; then
  AGENT="/Users/$SUDO_USER/Library/LaunchAgents/local.fanboost.plist"
  launchctl bootout "gui/$(id -u "$SUDO_USER")" "$AGENT" 2>/dev/null || true
  rm -f "$AGENT"
fi
pkill -x FanBoost || true
/usr/local/bin/fanctl auto || true
rm -f /usr/local/bin/fanctl /etc/sudoers.d/fanboost
rm -rf /Applications/FanBoost.app
echo "uninstalled"
