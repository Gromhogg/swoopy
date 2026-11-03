#!/bin/bash
# Installs Swoopy on a Mac: downloads the installer package and runs it (asks for your Mac password once).
# Use: curl -fsSL https://raw.githubusercontent.com/Gromhogg/swoopy/main/install.sh | bash
set -euo pipefail

repo="Gromhogg/swoopy"

version="$(sw_vers -productVersion)"
major="${version%%.*}"
rest="${version#*.}"
minor="${rest%%.*}"
if [ "$major" -lt 14 ] || { [ "$major" -eq 14 ] && [ "$minor" -lt 4 ]; }; then
  echo "Sorry, Swoopy needs macOS 14.4 or newer (this Mac has $version)."
  exit 1
fi

pkg="${SWOOPY_PKG:-${PITCH_SHIFT_PKG:-}}"  # for testing: a local Swoopy.pkg
if [ -z "$pkg" ]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading Swoopy..."
  pkg="$tmp/Swoopy.pkg"
  # Releases from before the name Swoopy only have PitchShift.pkg.
  curl -fsSL "https://github.com/$repo/releases/latest/download/Swoopy.pkg" -o "$pkg" 2>/dev/null \
    || curl -fsSL "https://github.com/$repo/releases/latest/download/PitchShift.pkg" -o "$pkg"
fi

echo "Type your Mac password to install Swoopy and Swoopy Mic (nothing shows while you type)."
sudo installer -pkg "$pkg" -target / >/dev/null

old_app="/Applications/Pitch Shift.app"
app="/Applications/Swoopy.app"
if [ ! -e "$app" ]; then app="$old_app"; fi
name="$(basename "$app" .app)"

# A shortcut on the Desktop, in place of an older one (or a whole copy of the app, which version 1 put there).
ours() { [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null)" = local.pitch-shift ]; }
old="$HOME/Desktop/Pitch Shift.app"
if [ -L "$old" ]; then
  if [ "$(readlink "$old")" = "$old_app" ]; then rm -f "$old" 2>/dev/null || true; fi
elif ours "$old"; then
  rm -rf "$old" 2>/dev/null || true
fi
desktop="$HOME/Desktop/$name.app"
if [ ! -e "$desktop" ] || [ -L "$desktop" ]; then ln -sfn "$app" "$desktop" 2>/dev/null || true; fi
echo "Installed $name. It's in Applications and on your Desktop."
if [ -z "${SWOOPY_NO_OPEN:-${PITCH_SHIFT_NO_OPEN:-}}" ]; then open "$app"; fi
