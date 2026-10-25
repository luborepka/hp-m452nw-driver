#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
arch="${ARCH:-$(uname -m)}"
app='build/HP M452nw Driver.app'
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ -z "${RELEASE_TAG:-}" || "$RELEASE_TAG" == "v$version" ]] || { echo 'Git tag does not match the bundle version' >&2; exit 1; }
[[ "$arch" == arm64 || "$arch" == x86_64 ]] || { echo 'Unsupported architecture' >&2; exit 1; }
lipo "$app/Contents/MacOS/hp-open-print" -verify_arch "$arch"
codesign --verify --deep --strict "$app"
if find "$app" -type f | /usr/bin/grep -E '\.(py|swift|o)$|hp-open-print-tests' >/dev/null; then
  echo 'Development files found in release bundle' >&2; exit 1
fi
stage="build/package-$arch"
rm -rf "$stage"
mkdir -p "$stage/payload" "$stage/scripts" build/release
cp -R "$app" "$stage/payload/"
cat > "$stage/components.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><array><dict>
<key>RootRelativeBundlePath</key><string>HP M452nw Driver.app</string>
<key>BundleIsRelocatable</key><false/>
<key>BundleHasStrictIdentifier</key><true/>
<key>BundleIsVersionChecked</key><true/>
<key>BundleOverwriteAction</key><string>upgrade</string>
</dict></array></plist>
PLIST
for operation in install remove; do
  identifier="org.hpopenprint.driver.$operation"
  cp Packaging/preinstall "$stage/scripts/preinstall"
  sed "s/operation=install/operation=$operation/" Packaging/postinstall > "$stage/scripts/postinstall"
  chmod +x "$stage/scripts/"*
  payload=(--nopayload)
  [[ "$operation" != install ]] || payload=(--root "$stage/payload" --component-plist "$stage/components.plist" --install-location '/Library/Application Support/HP Open Print/Driver')
  pkgbuild "${payload[@]}" --identifier "$identifier" --version "$version" --scripts "$stage/scripts" --compression latest --min-os-version 13.0 "$stage/$operation.pkg"
  cat > "$stage/Distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>HP M452nw Driver — $operation</title>
  <options customize="never" hostArchitectures="$arch"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <allowed-os-versions><os-version min="13.0"/></allowed-os-versions>
  <choices-outline><line choice="driver"/></choices-outline>
  <choice id="driver" visible="false"><pkg-ref id="$identifier"/></choice>
  <pkg-ref id="$identifier" version="$version">$operation.pkg</pkg-ref>
</installer-gui-script>
XML
  archive="hp-m452nw-driver-$version-$arch-$operation.pkg"
  productbuild --distribution "$stage/Distribution.xml" --resources "$stage" --package-path "$stage" "build/release/$archive"
  (cd build/release && shasum -a 256 "$archive" > "$archive.sha256")
  echo "Release: $archive ($(stat -f %z "build/release/$archive") bytes)"
done
