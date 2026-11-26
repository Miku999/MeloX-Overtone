#!/bin/bash
set -euo pipefail

# 产出 QQ 音乐版本 MeloX 的 unsigned IPA。
# 本脚本不改原项目配置，所有身份替换都在临时 xcodeproj / Info.plist 副本上完成。
#
# 用法：
#   bash build_qq_unsigned.sh
#   BUILD_DIR=/tmp/qqout bash build_qq_unsigned.sh
#   SDK26_COMPAT=0 bash build_qq_unsigned.sh   # 有 Xcode 27.1+ 时启用折叠屏分屏布局
#
# 环境变量：
#   SDK26_COMPAT  默认 1。置 1 时注入 MELOX_NO_IOS27，剔除 iOS 27.1 专属 API，
#                 使只有 iOS 26 SDK 的 Xcode 也能编译；置 0 则保留全部布局。
#   QQ_APP_DISPLAY_NAME  桌面显示名，默认 "Overtone QQ"
#
# 产物：$BUILD/MeloX-QQMusic-unsigned.ipa

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build}"
PROJECT="$ROOT/MeloX.xcodeproj"
SCHEME="MeloX"
APP_NAME="MeloX"
DERIVED_DATA="$BUILD/DerivedData-QQ"
STAGING="$BUILD/IPA-QQ"
IPA_PATH="$BUILD/MeloX-QQMusic-unsigned.ipa"
# 显示名默认 ASCII，避免 PlistBuddy 在非 UTF-8 locale 下写坏中文。
# 想用中文名就显式传：QQ_APP_DISPLAY_NAME="弦外QQ" bash build_qq_unsigned.sh
DISPLAY_NAME="${QQ_APP_DISPLAY_NAME:-Overtone QQ}"

TEMP_PROJECT=""
TEMP_APP_INFO=""
TEMP_WATCH_INFO=""
ICON_STASH=""
ICON_MOVED=()

restore_icons() {
  local pair src dst
  for pair in ${ICON_MOVED[@]+"${ICON_MOVED[@]}"}; do
    src="${pair%%|*}"
    dst="${pair##*|}"
    if [[ -e "$dst" && ! -e "$src" ]]; then
      mv "$dst" "$src"
    fi
  done
  if [[ -n "$ICON_STASH" && -d "$ICON_STASH" ]]; then
    rmdir "$ICON_STASH" 2>/dev/null || true
  fi
  return 0
}

cleanup() {
  restore_icons
  [[ -n "$TEMP_PROJECT" && -e "$TEMP_PROJECT" ]] && rm -rf -- "$TEMP_PROJECT"
  [[ -n "$TEMP_APP_INFO" && -f "$TEMP_APP_INFO" ]] && rm -f -- "$TEMP_APP_INFO"
  [[ -n "$TEMP_WATCH_INFO" && -f "$TEMP_WATCH_INFO" ]] && rm -f -- "$TEMP_WATCH_INFO"
  return 0
}
trap cleanup EXIT INT TERM

SDK26_COMPAT="${SDK26_COMPAT:-1}"
# Icon Composer 的两个 .icon 包是 Xcode 27 的格式，Xcode 26 的 actool 打开即崩。
# 默认跟随 SDK26_COMPAT：置 1 时改用 Assets.xcassets 里的经典 AppIcon.appiconset。
ICON_COMPAT="${ICON_COMPAT:-$SDK26_COMPAT}"

rm -rf "$DERIVED_DATA" "$STAGING"
rm -f "$IPA_PATH"
mkdir -p "$BUILD"

# 上次被强杀时图标可能还留在 stash 里，先自愈再继续，避免 mv 嵌套丢图标。
if [[ -d "$BUILD/icon-stash" ]]; then
  for leftover in "$BUILD/icon-stash"/*.icon; do
    [[ -d "$leftover" ]] || continue
    icon_target="$ROOT/MeloX/$(basename "$leftover")"
    if [[ ! -e "$icon_target" ]]; then
      mv "$leftover" "$icon_target"
      echo "restored leftover icon / 已还原残留图标：$(basename "$leftover")"
    fi
  done
fi

TEMP_PROJECT="$ROOT/.MeloX-QQ-Build-$$.xcodeproj"
TEMP_APP_INFO="$BUILD/MeloX-QQ-Info-$$.plist"
TEMP_WATCH_INFO="$BUILD/MeloXWatch-QQ-Info-$$.plist"

if [[ -e "$TEMP_PROJECT" || -e "$TEMP_APP_INFO" || -e "$TEMP_WATCH_INFO" ]]; then
  echo "Temporary build input exists; refusing to overwrite / 临时构建输入已存在"
  exit 1
fi

echo "========== Prepare temporary project / 准备临时工程 =========="

if [[ "$ICON_COMPAT" == "1" ]]; then
  ICON_STASH="$BUILD/icon-stash"
  for icon in "$ROOT/MeloX/AppIcon.icon" "$ROOT/MeloX/AppIconClassic.icon"; do
    if [[ -d "$icon" ]]; then
      mkdir -p "$ICON_STASH"
      mv "$icon" "$ICON_STASH/$(basename "$icon")"
      ICON_MOVED+=("$icon|$ICON_STASH/$(basename "$icon")")
      echo "  icon excluded (Xcode 26 actool can not read .icon) / 已排除：$(basename "$icon")"
    fi
  done
fi

ditto --norsrc "$PROJECT" "$TEMP_PROJECT"
ditto --norsrc "$ROOT/MeloX/Info.plist" "$TEMP_APP_INFO"
ditto --norsrc "$ROOT/MeloXWatch/Info.plist" "$TEMP_WATCH_INFO"

TEMP_PROJECT_NAME="$(basename "$TEMP_PROJECT")"

# Scheme 里的 container 指向原工程名，复制后必须跟着改。
find "$TEMP_PROJECT" -name '*.xcscheme' -type f -exec \
  sed -i '' "s#container:MeloX\.xcodeproj#container:$TEMP_PROJECT_NAME#g" {} +

# QQ 版使用独立 bundle id，避免与网易云原版共存时互相覆盖数据。
# 替换顺序很重要：先长后缀（legacy 变体），再通用前缀。
PBX_SED_ARGS=()
if [[ "$ICON_COMPAT" == "1" ]]; then
  # alternate icon 的唯一来源是 AppIconClassic.icon，被排除后 asset catalog 里
  # 没有同名 appiconset，留着这行会让 actool 报找不到 AppIconClassic。
  PBX_SED_ARGS+=(-e '/ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = AppIconClassic;/d')
fi

sed -i '' \
  -e 's/com\.aritxonly\.legacy\.MeloX/com.aritxonly.qqmusic.MeloX/g' \
  -e 's/com\.aritxonly\.MeloX/com.aritxonly.qqmusic.MeloX/g' \
  -e "s#INFOPLIST_FILE = MeloX/Info.plist;#INFOPLIST_FILE = \"$TEMP_APP_INFO\";#g" \
  -e "s#INFOPLIST_FILE = MeloXWatch/Info.plist;#INFOPLIST_FILE = \"$TEMP_WATCH_INFO\";#g" \
  ${PBX_SED_ARGS[@]+"${PBX_SED_ARGS[@]}"} \
  "$TEMP_PROJECT/project.pbxproj"

# App 显示名与 Watch 配套 bundle id。
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $DISPLAY_NAME" "$TEMP_APP_INFO"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $DISPLAY_NAME" "$TEMP_APP_INFO"
/usr/libexec/PlistBuddy \
  -c "Set :WKCompanionAppBundleIdentifier com.aritxonly.qqmusic.MeloX" \
  "$TEMP_WATCH_INFO"

echo "========== Build QQ Music iOS Release / 构建 QQ 音乐版 =========="

# 只有 iOS 26 SDK 的工具链没有 ArrangementView / reservedRegions 等 27.1 API，
# 注入这个标志让 4 个文件退回到功能等价的旧路径。
SDK26_COMPAT="${SDK26_COMPAT:-1}"
SDK26_SETTING=""
if [[ "$SDK26_COMPAT" == "1" ]]; then
  SDK26_SETTING="SWIFT_ACTIVE_COMPILATION_CONDITIONS=MELOX_NO_IOS27"
fi

echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
echo "SDK26_COMPAT=$SDK26_COMPAT"

xcodebuild clean build \
  -project "$TEMP_PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA" \
  REGISTER_APP_GROUPS=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGN_ENTITLEMENTS="" \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  $SDK26_SETTING

APP_PATH="$(find "$DERIVED_DATA/Build/Products/Release-iphoneos" -maxdepth 2 -name "$APP_NAME.app" -type d -print -quit)"
[[ -n "$APP_PATH" ]] || { echo "Build artifact not found / 找不到构建产物"; exit 1; }

echo "========== Verify bundle identities / 校验 Bundle ID =========="

assert_bundle() {
  local path="$1"
  local expected="$2"
  local label="$3"
  if [[ ! -f "$path/Info.plist" ]]; then
    echo "::error::$label Info.plist missing / 缺少 Info.plist：$path"
    exit 1
  fi
  local actual
  actual="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$path/Info.plist")"
  if [[ "$actual" != "$expected" ]]; then
    echo "::error::$label bundle id mismatch: got $actual, expected $expected"
    exit 1
  fi
  echo "  OK $label -> $actual"
}

assert_bundle "$APP_PATH" "com.aritxonly.qqmusic.MeloX" "App"
assert_bundle "$APP_PATH/PlugIns/MeloXLyricsWidget.appex" \
  "com.aritxonly.qqmusic.MeloX.LyricsWidget" "Widget"
assert_bundle "$APP_PATH/Watch/MeloX Watch App.app" \
  "com.aritxonly.qqmusic.MeloX.watchkitapp" "Watch"

WATCH_COMPANION="$(
  /usr/libexec/PlistBuddy \
    -c 'Print :WKCompanionAppBundleIdentifier' \
    "$APP_PATH/Watch/MeloX Watch App.app/Info.plist"
)"
if [[ "$WATCH_COMPANION" != "com.aritxonly.qqmusic.MeloX" ]]; then
  echo "::error::Watch companion bundle id mismatch: $WATCH_COMPANION"
  exit 1
fi
echo "  OK Watch companion -> $WATCH_COMPANION"

# QQ 版保留下载能力（AppFeatureAvailability 仅在 com.aritxonly.MeloX 前缀下关闭下载）。
echo "========== Create unsigned IPA / 生成未签名 IPA =========="

mkdir -p "$STAGING/Payload"
ditto --norsrc "$APP_PATH" "$STAGING/Payload/$APP_NAME.app"
ditto -c -k --norsrc --keepParent "$STAGING/Payload" "$IPA_PATH"

[[ -f "$IPA_PATH" ]] || { echo "Failed to create unsigned IPA / 生成未签名 IPA 失败"; exit 1; }

unzip -tq "$IPA_PATH"
ls -lh "$IPA_PATH"
shasum -a 256 "$IPA_PATH"

echo "Generated / 已生成：$IPA_PATH"
