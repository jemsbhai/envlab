#!/bin/zsh
# Build, sign, install and launch on the paired iPhone.
set -e
# Your iPhone's identifier, from `xcrun devicectl list devices`. Run: DEVICE=<id> ./run-on-phone.sh
DEVICE=${DEVICE:?Set DEVICE to your iPhone identifier (xcrun devicectl list devices)}
cd "$(dirname "$0")"

# Check the phone is reachable first. Without this xcodebuild fails with a wall
# of destination output that buries the actual cause.
STATE=$(xcrun devicectl list devices 2>/dev/null | awk -v d="$DEVICE" '$0 ~ d {print}')
if [[ -z "$STATE" ]]; then
  echo "✗ Device $DEVICE is not paired with this Mac."
  exit 1
fi
# Test "unavailable" first — it contains "available" as a substring, so the
# obvious check passes when the phone is off.
if [[ "$STATE" == *unavailable* || ( "$STATE" != *available* && "$STATE" != *connected* ) ]]; then
  echo "✗ The iPhone is paired but not reachable right now."
  echo "  Plug it in, or unlock it and check it's on the same Wi-Fi as this Mac."
  exit 1
fi

echo "→ Building for the device…"
xcodegen generate >/dev/null
xcodebuild -project Dewin.xcodeproj -scheme Dewin -configuration Debug \
  -destination "id=$DEVICE" -allowProvisioningUpdates build \
  ${VERBOSE:+} ${VERBOSE:-"-quiet"}

APP=$(xcodebuild -project Dewin.xcodeproj -scheme Dewin -configuration Debug \
  -destination "id=$DEVICE" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{d=$2} / FULL_PRODUCT_NAME/{n=$2} END{print d"/"n}')

echo "→ Installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP" >/dev/null
xcrun devicectl device process launch --device "$DEVICE" io.occh.dewin >/dev/null
echo "✓ Running on the iPhone. (VERBOSE=1 ./run-on-phone.sh for full build output.)"
