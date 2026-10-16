#!/bin/bash
# Build, install and launch on a connected iPhone (Debug).
#
#   TEAM=ABCDE12345 BUNDLE_ID=com.example.moonlight scripts/run-device.sh
#
# TEAM       Apple Developer Team ID (required)
# BUNDLE_ID  bundle identifier to sign with (required, must be unique to your team)
# MODEL      product type to pick, e.g. iPhone17,2 (optional; default = first paired physical iPhone)
# DISPLAY_NAME  home-screen name (optional; default "Moonlight") — handy to tell it apart from the App Store build
#
# Values can also live in scripts/local.env (gitignored), which is sourced if present.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
: "${TEAM:?set TEAM=<Apple Team ID> (or put it in scripts/local.env)}"
: "${BUNDLE_ID:?set BUNDLE_ID=<your bundle id> (or put it in scripts/local.env)}"
MODEL=${MODEL:-}

DEV_JSON=$(mktemp -t ml-dev).json
xcrun devicectl list devices --json-output "$DEV_JSON" >/dev/null 2>&1
UDID=$(python3 - "$DEV_JSON" "$MODEL" <<'EOF'
import json, sys
devs = json.load(open(sys.argv[1]))['result']['devices']
model = sys.argv[2]
for x in devs:
    hw = x['hardwareProperties']
    if hw.get('reality') != 'physical' or hw.get('platform') != 'iOS':
        continue
    if model and hw.get('productType') != model:
        continue
    if not model and not hw.get('productType', '').startswith('iPhone'):
        continue
    conn = x.get('connectionProperties', {})
    # paired and currently reachable (USB or local network); offline devices have no transportType
    if conn.get('pairingState') != 'paired' or not conn.get('transportType'):
        continue
    print(hw['udid']); break
EOF
)
rm -f "$DEV_JSON"
[ -n "$UDID" ] || { echo "no paired physical iPhone found${MODEL:+ for MODEL=$MODEL}" >&2; exit 1; }
echo "device: ${MODEL:-auto} $UDID"

xcodebuild -project Moonlight.xcodeproj -scheme Moonlight -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  ${DISPLAY_NAME:+ML_DISPLAY_NAME="$DISPLAY_NAME"} build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
APP=build/Build/Products/Debug-iphoneos/Moonlight.app
xcrun devicectl device install app --device "$UDID" "$APP" | tail -2
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" | tail -1
