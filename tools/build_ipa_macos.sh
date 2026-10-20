#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
name=$(python3 -c 'import json;print(json.load(open("Config/project.json"))["name"])')
command -v xcodebuild >/dev/null || { echo "Xcode required: use GitHub Actions xcode-27 runner" >&2; exit 1; }
xcodebuild -project "$name.xcodeproj" -scheme "$name" \
 -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
 -derivedDataPath build/Derived CODE_SIGNING_ALLOWED=NO build
app="build/Derived/Build/Products/Release-iphoneos/$name.app"
[[ -f "$app/Info.plist" ]] || { echo "Missing built app" >&2; exit 1; }
rm -rf build/ipa
mkdir -p build/ipa/Payload build/dist
cp -R "$app" build/ipa/Payload/
rm -f "build/dist/$name-unsigned.ipa"
(cd build/ipa && zip -qr "../dist/$name-unsigned.ipa" Payload)
python3 tools/verify_ipa.py "build/dist/$name-unsigned.ipa"
(cd build/dist && shasum -a 256 "$name-unsigned.ipa" > "$name-unsigned.ipa.sha256")
