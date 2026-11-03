#!/bin/zsh
# Builds the "Swoopy Mic" audio driver (BlackHole with our own name and settings) into build/SwoopyMic.driver,
# for both Apple silicon and Intel Macs. kDriver_Name only makes the hidden device IDs (PitchShiftMic_UID and
# PitchShiftMic_2_UID) that the app, Discord and Zoom remember the mic by, so it stays as it is.
set -e
cd "${0:A:h}/.."
out=build/SwoopyMic.driver
rm -rf "$out"
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
clang -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=14.4 -std=gnu11 -Os -Wall -Wno-unused-function \
  -DkDriver_Name='"PitchShiftMic"' -DkPlugIn_BundleID='"local.pitch-shift.mic"' -DkPlugIn_Icon='"SwoopyMic.icns"' \
  -DkHas_Driver_Name_Format=0 -DkManufacturer_Name='"Swoopy"' -DkNumber_Of_Channels=2 \
  -DkDevice_Name='"Swoopy Mic"' -DkDevice_IsHidden=0 -DkDevice_HasInput=1 -DkDevice_HasOutput=0 \
  -DkDevice2_Name='"Swoopy Mic Output"' -DkDevice2_IsHidden=1 -DkDevice2_HasInput=0 -DkDevice2_HasOutput=1 \
  -DkCanBeDefaultSystemDevice=0 \
  driver/BlackHole.c -o "$out/Contents/MacOS/SwoopyMic" \
  -framework CoreFoundation -framework CoreAudio -framework Accelerate
cp driver/Info.plist "$out/Contents/Info.plist"
cp AppIcon.icns "$out/Contents/Resources/SwoopyMic.icns"
codesign --force --sign - --timestamp=none "$out"
