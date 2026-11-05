#!/usr/bin/env bash
#
# Builds, packages and (optionally) publishes a Perch release. Runs on your Mac,
# so it needs no CI secrets: it uses your `gh` login and the Sparkle key stored
# in your Keychain (account "perch", created with Sparkle's generate_keys).
#
# Usage:
#   Configuration/release/release.sh 1.0.0             # build + package only (dry run)
#   Configuration/release/release.sh 1.0.0 --publish   # also tag, upload, update the Homebrew tap
#
# Releases are signed ad-hoc (no paid Apple Developer account), so they are not
# notarized. The Homebrew cask clears the quarantine flag; DMG users use
# System Settings › Privacy & Security › Open Anyway on first launch.

set -euo pipefail

VERSION="${1:?Usage: release.sh <version> [--publish]}"
PUBLISH="${2:-}"
REPO="trieuluan/perch-mac"
TAP_REPO="trieuluan/homebrew-perch"
SPARKLE_ACCOUNT="perch"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/release/$VERSION"
DERIVED="$ROOT/build/release/DerivedData"
BUILD_NUMBER="$(git rev-list --count HEAD)"

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || die "version must look like 1.2.3 or 1.2.3-beta.1"
if [[ "$PUBLISH" == "--publish" ]]; then
  [[ -z "$(git status --porcelain)" ]] || die "commit your changes before publishing"
  command -v gh >/dev/null || die "the GitHub CLI (gh) is required to publish"
  git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"
fi

step "Building Perch $VERSION (build $BUILD_NUMBER), signed ad-hoc"
# Command-line settings outrank Configuration/Local.xcconfig, so releases are
# always ad-hoc even on a machine set up with a personal team.
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  build | grep -E "error:|warning: .*Perch|BUILD (SUCCEEDED|FAILED)" || true
APP="$DERIVED/Build/Products/Release/Perch.app"
[[ -d "$APP" ]] || die "build failed, no Perch.app"
codesign --verify --deep --strict "$APP" || die "app signature does not verify"

SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[[ -x "$SPARKLE_BIN/sign_update" ]] || die "Sparkle tools not found in $SPARKLE_BIN"

step "Packaging"
rm -rf "$OUT" && mkdir -p "$OUT"
DMG="$OUT/Perch.dmg"
if command -v dmgbuild >/dev/null 2>&1; then
  Configuration/dmg/create_dmg.sh "$APP" "$DMG" "Perch"
else
  echo "dmgbuild not installed; making a plain DMG (pip install -r Configuration/dmg/requirements.txt for the styled one)"
  STAGE="$(mktemp -d)"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Perch" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
fi
SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

step "Signing the update and writing the appcast"
SIGNATURE_ATTRS="$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")"
PREVIOUS="$OUT/previous-appcast.xml"
if gh release download -R "$REPO" --pattern appcast.xml --output "$PREVIOUS" >/dev/null 2>&1; then
  echo "extending the appcast of the latest release"
else
  rm -f "$PREVIOUS"
fi
python3 Configuration/release/update_appcast.py \
  --output "$OUT/appcast.xml" --previous "$PREVIOUS" \
  --version "$VERSION" --build "$BUILD_NUMBER" \
  --url "https://github.com/$REPO/releases/download/v$VERSION/Perch.dmg" \
  --signature-attrs "$SIGNATURE_ATTRS" \
  --release-notes "https://github.com/$REPO/releases/tag/v$VERSION"

sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$SHA256/g" \
  Configuration/release/perch.rb.template > "$OUT/perch.rb"

echo
echo "Built:   $DMG"
echo "SHA-256: $SHA256"
echo "Appcast: $OUT/appcast.xml"
echo "Cask:    $OUT/perch.rb"

[[ "$PUBLISH" == "--publish" ]] || { echo; echo "Dry run. Re-run with --publish to release."; exit 0; }

step "Tagging and creating the GitHub release"
git tag -a "v$VERSION" -m "Perch $VERSION"
git push origin "v$VERSION"
PRERELEASE=()
[[ "$VERSION" == *-* ]] && PRERELEASE=(--prerelease)
gh release create "v$VERSION" -R "$REPO" "$DMG" "$OUT/appcast.xml" \
  --title "Perch $VERSION" --generate-notes "${PRERELEASE[@]}"

step "Updating the Homebrew tap ($TAP_REPO)"
TAP_DIR="$(mktemp -d)"
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet
mkdir -p "$TAP_DIR/Casks"
cp "$OUT/perch.rb" "$TAP_DIR/Casks/perch.rb"
git -C "$TAP_DIR" add Casks/perch.rb
git -C "$TAP_DIR" commit -m "perch $VERSION" --quiet
git -C "$TAP_DIR" push --quiet
rm -rf "$TAP_DIR"

echo
echo "Released Perch $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
