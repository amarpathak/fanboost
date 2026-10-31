#!/bin/sh
# Builds FanBoost, installs fanctl as root-owned, lets your user run it without a
# password, and starts FanBoost at login. Run with: sudo ./install.sh
set -e
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo "run: sudo $0"; exit 1; }
USER_NAME="${SUDO_USER:?run via sudo}"
USER_ID="$(id -u "$USER_NAME")"

sudo -u "$USER_NAME" ./build.sh

install -o root -g wheel -m 755 fanctl /usr/local/bin/fanctl
echo "$USER_NAME ALL=(root) NOPASSWD: /usr/local/bin/fanctl" > /tmp/fanboost.sudoers
visudo -cf /tmp/fanboost.sudoers
install -o root -g wheel -m 440 /tmp/fanboost.sudoers /etc/sudoers.d/fanboost
rm /tmp/fanboost.sudoers

pkill -x FanBoost || true
rm -rf /Applications/FanBoost.app
cp -R FanBoost.app /Applications/
chown -R "$USER_NAME" /Applications/FanBoost.app

AGENT="/Users/$USER_NAME/Library/LaunchAgents/local.fanboost.plist"
sudo -u "$USER_NAME" mkdir -p "$(dirname "$AGENT")"
sudo -u "$USER_NAME" tee "$AGENT" > /dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.fanboost</string>
  <key>ProgramArguments</key><array><string>/Applications/FanBoost.app/Contents/MacOS/FanBoost</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
launchctl bootout "gui/$USER_ID" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$USER_ID" "$AGENT"
echo "installed. FanBoost is in your menu bar and starts at login."
