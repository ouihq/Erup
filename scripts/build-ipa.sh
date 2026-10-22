#!/usr/bin/env bash
# Builds the unsigned release IPA for SideStore and AltStore and names it after its version:
#
#   scripts/build-ipa.sh ["Release notes for a new version"]
#
# Output: build/Erup-<version>-<build>.ipa, and source.json updated to match it.
# The app and widget are only ad-hoc signed here, so they carry their entitlements (the App Group) for the
# store to read. The store replaces the signature with your own when it installs the app.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project Erup.xcodeproj -scheme Erup -configuration Release -sdk iphoneos \
  -derivedDataPath build/device CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build | tail -1

app=build/device/Build/Products/Release-iphoneos/Erup.app
rm -rf build/Payload build/Erup-unsigned.ipa
mkdir -p build/Payload
cp -R "$app" build/Payload/
for extension in build/Payload/Erup.app/PlugIns/*.appex; do
  codesign --force --sign - --entitlements App/ErupWidgets/ErupWidgets.entitlements "$extension"
done
codesign --force --sign - --entitlements App/Erup/Erup.entitlements build/Payload/Erup.app
(cd build && zip -qry Erup-unsigned.ipa Payload)

scripts/update-source.sh build/Erup-unsigned.ipa "${1:-}"
