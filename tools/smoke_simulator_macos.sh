#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/smoke
name=$(python3 -c 'import json;print(json.load(open("Config/project.json"))["name"])')
bundle=$(python3 -c 'import json;print(json.load(open("Config/project.json"))["bundleIdentifier"])')
xcodebuild -project "$name.xcodeproj" -scheme "$name" -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/Simulator CODE_SIGNING_ALLOWED=NO build > build/smoke/build.log 2>&1 || {
    tail -n 100 build/smoke/build.log
    exit 1
  }
device=$(xcrun simctl list devices available --json | python3 -c '
import json,sys
phones=[d for devices in json.load(sys.stdin)["devices"].values() for d in devices if "iPhone" in d["name"]]
if not phones: raise SystemExit("No available iPhone simulator")
phones.sort(key=lambda d: d["name"] != "iPhone 18 Pro Max")
print(phones[0]["udid"])
')
trap 'xcrun simctl shutdown "$device" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$device" || xcrun simctl bootstatus "$device" -b
xcrun simctl bootstatus "$device" -b
xcrun simctl install "$device" "build/Simulator/Build/Products/Debug-iphonesimulator/$name.app"
xcrun simctl launch "$device" "$bundle"
sleep 3
xcrun simctl spawn "$device" launchctl list > build/smoke/processes.log
python3 - "$bundle" <<'PY'
from pathlib import Path
import sys
rows=[line.split() for line in Path('build/smoke/processes.log').read_text().splitlines()]
if not any(len(row)>=3 and row[0].isdigit() and sys.argv[1] in row[-1] for row in rows):
    raise SystemExit('App exited after launch')
print('PASS: app process is running in the iPhone simulator; LiveContainer not tested')
PY
xcrun simctl io "$device" screenshot build/smoke/library.png
test_status=0
xcodebuild -project "$name.xcodeproj" -scheme "$name" -configuration Debug \
  -destination "platform=iOS Simulator,id=$device" -derivedDataPath build/Simulator \
  -parallel-testing-enabled NO -resultBundlePath build/SimulatorTests.xcresult CODE_SIGNING_ALLOWED=NO test > build/smoke/tests.log 2>&1 || test_status=$?
if [ "$test_status" -ne 0 ]; then
    tail -n 120 build/smoke/tests.log
fi
if [ -d build/SimulatorTests.xcresult ]; then
  xcrun xcresulttool export attachments --path build/SimulatorTests.xcresult --output-path build/smoke/previews
fi
exit "$test_status"
