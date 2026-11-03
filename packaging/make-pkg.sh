#!/bin/zsh
# Makes build/Swoopy.pkg (the double-click installer) from build/Swoopy.app.
# Use: packaging/make-pkg.sh 2.0.0   (run ./build.sh --no-install first)
set -e
cd "${0:A:h}/.."
version=$1
if [[ -z $version ]]; then echo "Use: packaging/make-pkg.sh 1.2.3"; exit 1; fi
root=build/pkgroot
rm -rf $root build/component.pkg build/component.plist build/Swoopy.pkg
mkdir -p $root
ditto --norsrc --noextattr --noqtn build/Swoopy.app $root/Swoopy.app
pkgbuild --analyze --root $root build/component.plist
# Always install to /Applications/Swoopy.app (otherwise Installer may "update" an old copy with the same bundle ID
# wherever it finds one, like the Desktop or /Applications/Pitch Shift.app).
i=0
while /usr/libexec/PlistBuddy -c "Print :$i" build/component.plist >/dev/null 2>&1; do
  plutil -replace $i.BundleIsRelocatable -bool NO build/component.plist
  i=$((i + 1))
done
[[ $i -gt 0 ]] || { echo "No app found in $root"; exit 1 }
chmod +x packaging/scripts/*
# The newer compression macOS 14.4 can unpack: the same files, a smaller download (about 9 MB less, mostly the voices).
pkgbuild --root $root --component-plist build/component.plist --install-location /Applications \
  --scripts packaging/scripts --identifier local.pitch-shift.pkg --version $version \
  --compression latest --min-os-version 14.4 build/component.pkg
sed "s/VERSION/$version/" packaging/distribution.xml > build/distribution.xml
productbuild --distribution build/distribution.xml --package-path build build/Swoopy.pkg
echo "Built build/Swoopy.pkg"
