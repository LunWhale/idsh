#!/bin/bash
# 免费个人团队签名（不含 App Group，分享面板不可用）。
# 首次运行会弹出钥匙串授权：输入登录密码并点「始终允许」。
# 需要 macOS 已登录 Xcode 账号，并已配对 iPad。
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM="${DEVELOPMENT_TEAM:-95DH689DJQ}"
ARCHIVE=/tmp/idsh-signed.xcarchive
EXPORT=dist/export-signed
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild -project app/idsh.xcodeproj -scheme idsh -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" archive \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES \
  CODE_SIGN_ENTITLEMENTS= -allowProvisioningUpdates
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist scripts/export-options.plist -allowProvisioningUpdates
cp "$EXPORT/idsh.ipa" dist/idsh-signed.ipa
shasum -a 256 dist/idsh-signed.ipa
