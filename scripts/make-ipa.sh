#!/bin/bash
# 构建未签名 iOS 设备 IPA（用于 SideStore / AltStore / Sideloadly 等自签工具）
# 用法：bash scripts/make-ipa.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ARCHIVE=/tmp/idsh-unsigned.xcarchive
STAGE=/tmp/idsh-ipa
OUT=dist/idsh-unsigned.ipa

rm -rf "$ARCHIVE" "$STAGE"
mkdir -p "$STAGE/Payload" dist

xcodebuild \
  -project app/idsh.xcodeproj \
  -scheme idsh \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  archive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO

cp -R "$ARCHIVE/Products/Applications/idsh.app" "$STAGE/Payload/idsh.app"
( cd "$STAGE" && zip -qry "$OLDPWD/$OUT" Payload )

echo "built: $OUT"
ls -lh "$OUT"
shasum -a 256 "$OUT"
