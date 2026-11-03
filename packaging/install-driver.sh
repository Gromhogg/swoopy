#!/bin/bash
# Installs the "Swoopy Mic" audio driver. Needs admin. Restarts the Mac's sound system (about one second
# of silence) only when the driver is new or changed.
# Use: sudo install-driver.sh [path/to/SwoopyMic.driver]   (default: the copy inside Swoopy.app)
set -euo pipefail
src="${1:-$(cd "$(dirname "$0")/.." && pwd)/PlugIns/SwoopyMic.driver}"
dest="/Library/Audio/Plug-Ins/HAL/SwoopyMic.driver"
old="/Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver"  # the same mic from older versions; both would show up
if [ ! -d "$src" ]; then echo "Can't find $src"; exit 1; fi
if [ -d "$dest" ] && [ ! -e "$old" ] && cmp -s "$src/Contents/MacOS/SwoopyMic" "$dest/Contents/MacOS/SwoopyMic" \
   && cmp -s "$src/Contents/Info.plist" "$dest/Contents/Info.plist"; then
  exit 0
fi
mkdir -p /Library/Audio/Plug-Ins/HAL
rm -rf "$dest" "$old"
ditto "$src" "$dest"
chown -R root:wheel "$dest"
chmod -R go-w "$dest"
xattr -cr "$dest"   # a driver marked "downloaded from the internet" is silently not loaded
killall coreaudiod 2>/dev/null || true
