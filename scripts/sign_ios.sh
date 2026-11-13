#!/bin/bash
# Give the unsigned build the entitlements its targets need, then repack.
#
# `flutter build ios --no-codesign` leaves every binary without an
# __entitlements section, so a TrollStore install has nothing to preserve and
# the packet tunnel comes up without NetworkExtension rights: the app opens,
# the switch flips, and nothing happens. ldid writes the entitlements into the
# Mach-O; TrollStore keeps them when it resigns with its fake root.
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

sign() {
  local binary="$1" template="$2"
  [ -f "$binary" ] || return 0
  local ent="$WORK/ent.plist"
  sed "s/\$(APP_BUNDLE_ID)/$BUNDLE_ID/g" "$template" > "$ent"
  ldid -S"$ent" "$binary"
}

sign "$APP/Runner" "$ROOT/ios/Runner/Runner.entitlements"
sign "$APP/PlugIns/NECore.appex/NECore" "$ROOT/ios/NECore/NECore.entitlements"
sign "$APP/PlugIns/Widget.appex/Widget" "$ROOT/ios/Widget/Widget.entitlements"

# Nested frameworks are loaded individually, so each one needs a signature too.
while IFS= read -r -d '' candidate; do
  if file -b "$candidate" | grep -q 'Mach-O'; then
    ldid -S "$candidate"
  fi
done < <(find "$APP/Frameworks" "$APP/PlugIns" -type f -perm -111 -print0 2>/dev/null)

# Pack beside the original and move it into place only once zip succeeded, so a
# failed repack never leaves the runner without a package.
(cd "$WORK" && zip -qry "$WORK/FlClash-resigned.ipa" Payload)
mv -f "$WORK/FlClash-resigned.ipa" "$IPA"
echo "resigned: $IPA"
