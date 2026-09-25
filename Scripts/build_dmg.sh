#!/usr/bin/env bash
#
# build_dmg.sh — MetriBar 打包脚本（Release archive + dmg）
#
# 用法：
#   ./Scripts/build_dmg.sh                                   # ad-hoc 签名，仅本机自用
#   ./Scripts/build_dmg.sh --identity "Developer ID Application: 名字 (TEAMID)"
#   ./Scripts/build_dmg.sh --identity "..." --notarize you@example.com TEAMID
#
# 产物：dist/MetriBar-<version>.dmg
#
set -euo pipefail

IDENTITY=""                 # 留空 = ad-hoc 签名
NOTARIZE_ACCOUNT=""
NOTARIZE_TEAM=""
KEYCHAIN_PROFILE="MetriBar-Notary"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="MetriBar.xcodeproj"
SCHEME="MetriBar"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
STAGING="$BUILD/staging"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)   IDENTITY="$2"; shift 2 ;;
    --notarize)   NOTARIZE_ACCOUNT="$2"; NOTARIZE_TEAM="$3"; shift 3 ;;
    -h|--help)    sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：$1（用 --help 查看用法）" >&2; exit 64 ;;
  esac
done

cd "$ROOT"

# ---------------------------------------------------------------- 1. archive
echo "▸ archive（$SCHEME / Release）"
rm -rf "$BUILD"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$BUILD/MetriBar.xcarchive" \
  archive

APP="$BUILD/MetriBar.xcarchive/Products/Applications/MetriBar.app"
[[ -d "$APP" ]] || { echo "✗ 未找到 $APP" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "▸ MetriBar $VERSION"

# ---------------------------------------------------------------- 2. staging（带 /Applications 快捷方式）
rm -rf "$STAGING" "$DIST"; mkdir -p "$STAGING" "$DIST"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
[[ -f "$ROOT/README.md" ]] && cp "$ROOT/README.md" "$STAGING/README.md"

# ---------------------------------------------------------------- 3. 签名
if [[ -n "$IDENTITY" ]]; then
  echo "▸ codesign → $IDENTITY"
  # entitlements 里 app-sandbox=false，必须随签名固化，否则 SMC 读不到数据
  codesign --force --deep --options runtime \
    --entitlements "$ROOT/MetriBar.entitlements" \
    --timestamp \
    --sign "$IDENTITY" "$STAGING/MetriBar.app"
else
  echo "▸ codesign → ad-hoc（无 Developer ID，只能本机或手动拷贝运行）"
  codesign --force --deep --sign - "$STAGING/MetriBar.app"
fi
codesign --verify --deep --strict --verbose=2 "$STAGING/MetriBar.app"

# ---------------------------------------------------------------- 4. dmg
DMG="$DIST/MetriBar-${VERSION}.dmg"
echo "▸ hdiutil create → $DMG"
rm -f "$DMG"
hdiutil create -volname "MetriBar" -srcfolder "$STAGING" -ov -format UDZO "$DMG"

# ---------------------------------------------------------------- 5. 签名 + 公证（可选）
if [[ -n "$IDENTITY" ]]; then
  codesign --timestamp --sign "$IDENTITY" "$DMG"
  if [[ -n "$NOTARIZE_ACCOUNT" ]]; then
    echo "▸ notarytool submit（首次需先存凭据：xcrun notarytool store-credentials $KEYCHAIN_PROFILE …）"
    xcrun notarytool submit "$DMG" \
      --apple-id "$NOTARIZE_ACCOUNT" \
      --team-id "$NOTARIZE_TEAM" \
      --keychain-profile "$KEYCHAIN_PROFILE" \
      --wait
    xcrun stapler staple "$DMG"
  fi
fi

spctl -a -vv -t open --context context:primary-signature "$DMG" 2>/dev/null || \
  echo "ℹ️  spctl 未通过（ad-hoc 签名属正常现象）"

echo "✓ 完成：$DMG"
du -h "$DMG" | awk '{print "  大小："$1}'
