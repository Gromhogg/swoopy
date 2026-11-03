#!/bin/zsh
# Builds the Mac installer (Swoopy.pkg) and app zip, and posts them as a new GitHub release.
# The Windows build on GitHub Actions then adds Swoopy-Setup.exe to the same release.
# Use: ./release.sh 2.0.0   (commit and push your changes first)
set -e
cd "${0:A:h}"
version=$1
if [[ -z $version ]]; then echo "Use: ./release.sh 1.2.3"; exit 1; fi
# Swoopy Pro: build.sh builds in the public key from ~/Library/Application Support/Pitch Shift Keys/
# signing-public.txt (or PRO_PUBLIC_KEY), so the paid parts are locked, and the older keys from issued.txt there (or
# PRO_ISSUED), so the keys sent out before signed keys keep working. Without the public key the release would have
# nothing locked, and without issued.txt the older keys would stop working, so it stops, unless that's what's wanted:
# PRO_PUBLIC_KEY= ./release.sh 1.2.3 (everything free), PRO_ISSUED= ./release.sh 1.2.3 (no older keys).
keys_dir="$HOME/Library/Application Support/Pitch Shift Keys"
if [[ -z ${PRO_PUBLIC_KEY+x} && ! -s "$keys_dir/signing-public.txt" ]]; then
  echo "No Swoopy Pro public key on this Mac ($keys_dir/signing-public.txt), so this release would have nothing"
  echo "locked. Make the key pair with tools/pro-keys.sh setup (or copy the saved Pitch Shift Keys folder back), or"
  echo "release with everything free: PRO_PUBLIC_KEY= ./release.sh $version"
  exit 1
fi
if [[ -n ${PRO_PUBLIC_KEY-x} && -z ${PRO_ISSUED+x} && ! -f "$keys_dir/issued.txt" ]]; then
  echo "No list of keys sent out ($keys_dir/issued.txt), so the older keys people already have would stop working."
  echo "Copy the saved Pitch Shift Keys folder back, or release without them: PRO_ISSUED= ./release.sh $version"
  exit 1
fi
# The app's version only; the Swoopy Mic driver keeps its own version so updates don't restart Mac sound.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" -c "Set :CFBundleVersion $version" Info.plist
./build.sh --no-install
packaging/make-pkg.sh $version
rm -f build/Swoopy.zip
ditto -c -k --keepParent build/Swoopy.app build/Swoopy.zip
gh release create "v$version" build/Swoopy.pkg build/Swoopy.zip --title "Swoopy $version" \
  --notes "Install or update: see the README. Mac: Swoopy.pkg. Windows (beta): Swoopy-Setup.exe (added a few minutes after the Mac files)."
