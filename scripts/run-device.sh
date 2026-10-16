#!/bin/bash
# 编译并装到主人的 iPhone 18 Pro Max（按型号 iPhone19,3 解析 UDID），签名用小家 Team
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM=$(grep -h DEVELOPMENT_TEAM ../novel-reader-ios/project.yml | head -1 | awk '{print $2}' | tr -d '"')
MODEL=${MODEL:-iPhone19,3}
UDID=$(xcrun devicectl list devices --json-output /tmp/ml-dev.json >/dev/null 2>&1; python3 -c "
import json;d=json.load(open('/tmp/ml-dev.json'))
for x in d['result']['devices']:
    if x['hardwareProperties'].get('productType')=='$MODEL' and x['hardwareProperties'].get('reality')=='physical':
        print(x['hardwareProperties']['udid']);break")
echo "device: $MODEL $UDID"
xcodebuild -project Moonlight.xcodeproj -scheme Moonlight -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER=me.kiyor.moonlight build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=build/Build/Products/Debug-iphoneos/Moonlight.app
xcrun devicectl device install app --device "$UDID" "$APP" | tail -2
xcrun devicectl device process launch --device "$UDID" me.kiyor.moonlight | tail -1
