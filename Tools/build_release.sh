#!/bin/bash
#
# Builds a universal (arm64 + x86_64) Release Кика.app and zips it.
# Used by .github/workflows/ci.yml; works the same locally.
#
# Usage:
#   Tools/build_release.sh <version> [out-dir]
#     version   CFBundleShortVersionString, e.g. 0.3.0 (the top CHANGELOG.md section)
#     out-dir   default build/<version>; gets Кика.app + Kika-<version>-alpha-universal.zip
#               (the zip name stays ASCII: GitHub strips non-ASCII from release asset names)
#
# Env:
#   SIGN_IDENTITY   unset = the project's own signing (Automatic, the owner's Apple Development cert);
#                   "-" = ad-hoc; anything else = that identity with manual signing (CI imports the
#                   owner's Apple Development cert, so builds keep the same container + folder access).
#   BUILD_NUMBER    CFBundleVersion, default = commit count.
#   DERIVED_DATA    default /private/tmp/claude-501/dd-release
#
set -euo pipefail

VERSION="${1:?usage: $0 <version> [out-dir]}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${2:-$REPO/build/$VERSION}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$REPO" rev-list --count HEAD)}"
DERIVED_DATA="${DERIVED_DATA:-/private/tmp/claude-501/dd-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

SIGNING=()
if [ -n "${SIGN_IDENTITY+x}" ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
  else
    SIGNING=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY" PROVISIONING_PROFILE_SPECIFIER=)
  fi
fi

xcodebuild -project "$REPO/Kika.xcodeproj" -scheme Kika -configuration Release \
  -derivedDataPath "$DERIVED_DATA" -destination 'generic/platform=macOS' \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ${SIGNING[@]+"${SIGNING[@]}"} \
  build

NAME="Кика"   # PRODUCT_NAME: Кика.app, executable Кика
APP="$DERIVED_DATA/Build/Products/Release/$NAME.app"
codesign --verify --deep --strict "$APP"
archs="$(lipo -archs "$APP/Contents/MacOS/$NAME")"
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal: $archs" >&2; exit 1 ;; esac

mkdir -p "$OUT"
ZIP="$OUT/Kika-$VERSION-alpha-universal.zip"
if [ -e "$OUT/$NAME.app" ] || [ -e "$ZIP" ]; then
  echo "$OUT already has a build; remove it first" >&2
  exit 1
fi
ditto "$APP" "$OUT/$NAME.app"
ditto -c -k --keepParent "$OUT/$NAME.app" "$ZIP"
echo "Built $VERSION ($BUILD_NUMBER, $archs): $ZIP"
