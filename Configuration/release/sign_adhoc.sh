#!/usr/bin/env bash
set -euo pipefail

APP="${1:?Usage: sign_adhoc.sh <app>}"
if ! codesign -dv "$APP" 2>&1 | grep '^Signature=adhoc$' >/dev/null; then
  echo "error: refusing to change a non-ad-hoc signature: $APP" >&2
  exit 1
fi

ENTITLEMENTS="$(mktemp)"
trap 'rm -f "$ENTITLEMENTS"' EXIT
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
/usr/libexec/PlistBuddy -c 'Delete :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS" 2>/dev/null || true
/usr/libexec/PlistBuddy -c 'Add :com.apple.security.cs.disable-library-validation bool true' "$ENTITLEMENTS"
codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" > "$ENTITLEMENTS" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.cs.disable-library-validation' "$ENTITLEMENTS")" == true ]]
