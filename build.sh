#!/bin/sh
# ./build.sh          -> dist/Strain.app (universal: Apple silicon + Intel, signed with Reaktif LLC's Developer ID, else ad-hoc)
# ./build.sh install  -> also installs to ~/Applications and relaunches
# Also writes dist/Strain.zip + .sha256. Optional env: VERSION, SIGN_IDENTITY (else the Reaktif LLC Developer ID in
# the keychain), NOTARY_KEY/NOTARY_KEY_ID/NOTARY_ISSUER (App Store Connect API key) to notarize.
set -eu
cd "$(dirname "$0")"
ARCHS="--arch arm64 --arch x86_64"  # one binary for Apple silicon and Intel Macs
swift build -c release $ARCHS
APP=dist/Strain.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
BIN=$(swift build -c release $ARCHS --show-bin-path)
mkdir -p "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Strain" "$BIN/StrainHelper" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
[ -n "${VERSION:-}" ] && plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
cp Resources/Helper/com.josephgoksu.strain.helper.plist "$APP/Contents/Library/LaunchDaemons/"
cp Resources/explanations.json "$APP/Contents/Resources/"
[ -f Resources/Strain.icns ] && cp Resources/Strain.icns "$APP/Contents/Resources/"
# A stable certificate keeps macOS permissions (Bluetooth, Automation) across rebuilds, and the helper and Strain
# check each other's team (HelperKit.team) before they talk. Ad-hoc builds run, but without the helper.
SIGN=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application: Reaktif LLC/ {print $2; exit}')}
STAMP=--timestamp=none
[ -n "${NOTARY_KEY:-}" ] && STAMP=--timestamp  # notarization needs Apple's secure timestamp (network)
codesign --force --options runtime $STAMP --identifier com.josephgoksu.strain.helper --sign "${SIGN:--}" "$APP/Contents/MacOS/StrainHelper"
codesign --force --options runtime $STAMP --entitlements Resources/Strain.entitlements --sign "${SIGN:--}" "$APP"
zip_app() {
  rm -f dist/Strain.zip* && ditto -c -k --keepParent "$APP" dist/Strain.zip
  (cd dist && shasum -a 256 Strain.zip > Strain.zip.sha256)
}
zip_app
if [ -n "${NOTARY_KEY:-}" ]; then
  xcrun notarytool submit dist/Strain.zip --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$APP"
  zip_app  # zip again so the download carries the stapled ticket
fi
if [ "${1:-}" = install ]; then
  pkill -x Strain || true
  mkdir -p ~/Applications && rm -rf ~/Applications/Strain.app && cp -R "$APP" ~/Applications/
  open ~/Applications/Strain.app
fi
