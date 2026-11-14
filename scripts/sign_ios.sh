#!/bin/bash
# Give the unsigned build the entitlements its targets need, then repack.
#
# `flutter build ios --no-codesign` leaves every binary without an
# __entitlements section, so a TrollStore install has nothing to preserve and
# the packet tunnel comes up without NetworkExtension rights: the app opens,
# the switch flips, and nothing happens. An ad-hoc codesign writes the
# entitlements into the Mach-O; TrollStore keeps them when it resigns with its
# fake root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IPA="${1:-$ROOT/dist/FlClash.ipa}"
# The caller passes a repo-relative path; zip runs from the temp directory, so
# resolve it once and keep using the absolute form.
IPA_DIR="$(cd "$(dirname "$IPA")" && pwd)"
IPA="$IPA_DIR/$(basename "$IPA")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$IPA" ] || { echo "missing $IPA" >&2; exit 1; }

unzip -q "$IPA" -d "$WORK"
APP="$WORK/Payload/Runner.app"
[ -d "$APP" ] || { echo "no Runner.app in $IPA" >&2; exit 1; }

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
echo "bundle id: $BUNDLE_ID"

# Alternate app icons must be declared in Info.plist and shipped as standalone
# PNGs before anything is signed. Changing Info.plist after a codesign would
# invalidate that signature, so this has to be the very first mutation.
python3 "$ROOT/scripts/prepare_ios_icons.py" \
  --app "$APP" \
  --assets "$ROOT/ios/Runner/Assets.xcassets"

sign_with_entitlements() {
  local binary="$1" template="$2" label="$3"
  [ -f "$binary" ] || {
    echo "missing binary for $label: $binary" >&2
    exit 1
  }
  [ -f "$template" ] || {
    echo "missing entitlements template for $label: $template" >&2
    exit 1
  }
  local ent="$WORK/ent-$label.plist"
  sed "s/\$(APP_BUNDLE_ID)/$BUNDLE_ID/g" "$template" >"$ent"
  /usr/bin/codesign --force --sign - --timestamp=none --entitlements "$ent" "$binary"
  local keys
  keys=$(/usr/bin/codesign -d --entitlements - --xml "$binary" 2>/dev/null | grep -c '<key>' || true)
  echo "signed $label: $keys entitlement keys"
  if [ "$keys" -eq 0 ]; then
    echo "no entitlements written to $label" >&2
    exit 1
  fi
}

# Nested code is signed first: signing an outer bundle seals its contents, so a
# later change inside would invalidate it.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    /usr/bin/codesign --force --sign - --timestamp=none "$candidate"
  fi
done < <(find "$APP/Frameworks" -type f -perm -111 -print0 2>/dev/null)

sign_with_entitlements \
  "$APP/PlugIns/NECore.appex/NECore" \
  "$ROOT/ios/NECore/NECore.entitlements" \
  "NECore"
sign_with_entitlements \
  "$APP/PlugIns/Widget.appex/Widget" \
  "$ROOT/ios/Widget/Widget.entitlements" \
  "Widget"
sign_with_entitlements \
  "$APP/Runner" \
  "$ROOT/ios/Runner/Runner.entitlements" \
  "Runner"

# Pack beside the original and move it into place only once zip succeeded, so a
# failed repack never leaves the runner without a package.
(cd "$WORK" && zip -qry "$WORK/FlClash-resigned.ipa" Payload)
mv -f "$WORK/FlClash-resigned.ipa" "$IPA"
echo "resigned: $IPA"
