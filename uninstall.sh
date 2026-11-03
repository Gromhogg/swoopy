#!/bin/bash
# Removes Swoopy and Swoopy Mic from a Mac, and an older copy named Pitch Shift.
# Use: curl -fsSL https://raw.githubusercontent.com/Gromhogg/swoopy/main/uninstall.sh | bash
set -uo pipefail
echo "Type your Mac password to remove Swoopy (nothing shows while you type)."
sudo /bin/bash -c '
  pkill -x Swoopy 2>/dev/null && sleep 1
  pkill -x PitchShift 2>/dev/null && sleep 1
  old="/Applications/Pitch Shift.app"
  if [ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$old/Contents/Info.plist" 2>/dev/null)" = local.pitch-shift ]; then
    rm -rf "$old"
  fi
  rm -rf /Applications/Swoopy.app /Library/Audio/Plug-Ins/HAL/SwoopyMic.driver /Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver
  pkgutil --forget local.pitch-shift.pkg >/dev/null 2>&1
  killall coreaudiod 2>/dev/null
' || exit 1
for desktop in "$HOME/Desktop/Swoopy.app" "$HOME/Desktop/Pitch Shift.app"; do
  if [ -L "$desktop" ]; then rm "$desktop"; fi
done
defaults delete local.pitch-shift >/dev/null 2>&1
tccutil reset All local.pitch-shift >/dev/null 2>&1
echo "Swoopy is removed."
