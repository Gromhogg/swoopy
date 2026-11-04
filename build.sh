#!/bin/zsh
# Builds "Pitch Shift.app" (with the Pitch Shift Mic driver inside) into build/, then installs it in /Applications
# with a shortcut on the Desktop. Use ./build.sh --no-install to only build.
set -e
cd "${0:A:h}"
# Rubber Band and libsamplerate for Apple silicon and Intel (needs brew install rubberband).
./libs/build.sh
app=build/"Pitch Shift.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"

./driver/build.sh
ditto build/PitchShiftMic.driver "$app/Contents/PlugIns/PitchShiftMic.driver"

# The app is built twice, for Apple silicon (arm64) and Intel (x86_64), both for macOS 14.4 or newer,
# and joined into one file.
rm -rf build/obj
# Pitch Shift Pro: what the app checks keys with. Keys are signed with the owner's private key, which never leaves
# ~/Library/Application Support/Pitch Shift Keys; the app gets only the public half (it can check keys, not make
# them), from PRO_PUBLIC_KEY or else signing-public.txt in that folder (made by tools/pro-keys.sh setup), plus the
# fingerprints of the older 25-character keys sent out before signed keys, from PRO_ISSUED or else issued.txt in the
# same folder, so they keep working (tools/pro-config.sh; it never prints a key). With no public key (or
# PRO_PUBLIC_KEY= set to nothing) the app has nothing locked. The filled-in copy of ProConfig.swift is made in
# build/obj and deleted right after the app is built. (The old key secret, secret.txt, is no longer built in.)
swift_sources=(Sources/*.swift)
keys_dir="$HOME/Library/Application Support/Pitch Shift Keys"
if [[ -z ${PRO_PUBLIC_KEY+x} ]]; then
  PRO_PUBLIC_KEY=$( [[ -f $keys_dir/signing-public.txt ]] && tr -d ' \t\r\n' < "$keys_dir/signing-public.txt" || true )
fi
PRO_PUBLIC_KEY=${PRO_PUBLIC_KEY//[[:space:]]/}
[[ -n ${PRO_ISSUED+x} ]] || PRO_ISSUED=$keys_dir/issued.txt
if [[ -n $PRO_PUBLIC_KEY ]]; then
  mkdir -p build/obj
  old_keys=$(tools/pro-config.sh "$PRO_PUBLIC_KEY" "$PRO_ISSUED" build/obj/ProConfig.swift) || exit 1
  swift_sources=(${swift_sources:#Sources/ProConfig.swift} build/obj/ProConfig.swift)
  echo "Pitch Shift Pro: the paid parts are locked until a key is entered (public key built in; older keys that still work: $old_keys)"
else
  echo "Pitch Shift Pro: no public key, so nothing is locked in this build"
fi
for arch in arm64 x86_64; do
  obj=build/obj/$arch
  mkdir -p $obj
  # The C and C++ parts: the sound ring and the Advanced processing engine (Sources/Advanced).
  clang -arch $arch -mmacosx-version-min=14.4 -O2 -c Sources/AudioRing.c -o $obj/AudioRing.o
  for f in Sources/Advanced/*.cpp; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -Ibuild/libs/include -c "$f" -o "$obj/${f:t:r}.o"
  done
  # The voice changer: Natural mode (plain C++) and Realistic mode (Core ML, Objective-C++).
  for f in Sources/Voice/*.cpp; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -c "$f" -o "$obj/${f:t:r}.o"
  done
  for f in Sources/Voice/*.mm; do
    clang++ -arch $arch -mmacosx-version-min=14.4 -O2 -std=c++17 -fobjc-arc -Ibuild/libs/src/libsamplerate-0.2.2/include \
      -c "$f" -o "$obj/${f:t:r}.o"
  done
  # Rubber Band is built into the app, so the app works on its own. -dead_strip leaves out the code nothing calls.
  swiftc -target $arch-apple-macos14.4 -O -swift-version 5 $swift_sources $obj/*.o -o $obj/PitchShift \
    -import-objc-header Sources/Bridging.h -Ibuild/libs/include \
    -Xlinker build/libs/lib/librubberband.a -Xlinker build/libs/lib/libsamplerate.a -lc++ -framework Accelerate \
    -framework CoreML -Xlinker -dead_strip
done
lipo -create build/obj/arm64/PitchShift build/obj/x86_64/PitchShift -output "$app/Contents/MacOS/PitchShift"
rm -f build/obj/ProConfig.swift  # the filled-in copy (public key and older keys' fingerprints)

if [[ ! -f AppIcon.icns ]]; then
  swift make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o AppIcon.icns
fi
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns LICENSE packaging/install-driver.sh build/libs/lib/libsamplerate-COPYING "$app/Contents/Resources/"
# The voice changer's voices (settings, credits) and the Realistic mode's AI models. The models are too big for git
# (~150 MB): they come from a local copy (build/voices/ or research/voicechanger/models/, in this checkout or the main
# one) or are downloaded once into build/voices/ from the addresses in voices/models.txt, checked against their
# SHA-256 sums, and unpacked next to the voices' json files. Without them the app still builds (Realistic mode then
# says the files are missing; Natural mode works).
ditto voices "$app/Contents/Resources/Voices"
rm -f "$app/Contents/Resources/Voices/models.txt"
mkdir -p build/voices
main_checkout=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
main_checkout=${main_checkout:h}
while read -r name size sum url; do
  [[ -z $name || $name == \#* ]] && continue
  zip=build/voices/$name
  for dir in research/voicechanger/models $main_checkout/research/voicechanger/models; do
    [[ -f $zip ]] || [[ ! -f $dir/$name ]] || cp "$dir/$name" "$zip"
  done
  if [[ ! -f $zip ]] || ! echo "$sum  $zip" | shasum -a 256 -c --status; then
    if [[ -z $url || $url == *PLACEHOLDER* ]]; then
      echo "AI voice file $name: no local copy and no download address yet (voices/models.txt); Realistic mode will be missing it"
      continue
    fi
    echo "Downloading $name"
    curl -fL --retry 3 "$url" -o "$zip.part"
    echo "$sum  $zip.part" | shasum -a 256 -c --status || { echo "$name doesn't match its checksum"; exit 1; }
    mv "$zip.part" "$zip"
  fi
  ditto -x -k "$zip" "$app/Contents/Resources/Voices/"
done < voices/models.txt
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built $app"
[[ "$1" == "--no-install" ]] && exit 0

# Install here: the app in /Applications, a shortcut on the Desktop (replacing an old real copy there).
if [[ -e "/Applications/Pitch Shift.app" && ! -w "/Applications/Pitch Shift.app/Contents" ]]; then
  echo "Pitch Shift in Applications was put there by the installer package. Replace it with:"
  echo "  packaging/make-pkg.sh 0.0.0-dev && sudo installer -pkg build/PitchShift.pkg -target /"
  exit 1
fi
pkill -x PitchShift && sleep 1 || true
rm -rf "/Applications/Pitch Shift.app"
ditto "$app" "/Applications/Pitch Shift.app"
desktop=~/Desktop/"Pitch Shift.app"
[[ -e $desktop && ! -L $desktop ]] && rm -rf $desktop
ln -sfn "/Applications/Pitch Shift.app" $desktop
if ! cmp -s build/PitchShiftMic.driver/Contents/MacOS/PitchShiftMic /Library/Audio/Plug-Ins/HAL/PitchShiftMic.driver/Contents/MacOS/PitchShiftMic 2>/dev/null; then
  echo "Pitch Shift Mic is new or changed. Install it with: sudo packaging/install-driver.sh build/PitchShiftMic.driver"
fi
echo "Installed /Applications/Pitch Shift.app (shortcut on the Desktop)"
