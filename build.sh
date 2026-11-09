#!/bin/bash
# 构建 Faymee.app
#   ./build.sh            开发构建（Apple Development 签名，本机架构）→ build/Faymee.app
#   ./build.sh install    开发构建并安装到 /Applications/Faymee.app，然后启动
#
# 环境变量：
#   FAYMEE_TEAM_ID        签名所属团队（必填）。
#                         麦克风授权跟签名绑定，换团队后系统会重新询问权限
#   FAYMEE_SIGN_IDENTITY  开发签名证书（名称或 SHA-1），默认取该团队的 Apple Development 证书
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
BUILD="$ROOT/build"
APP="$BUILD/Faymee.app"
MODE="${1:-dev}"
TEAM_ID="${FAYMEE_TEAM_ID:-}"

# find_identity <证书类型>：输出 TEAM_ID 团队下该类型第一个有效证书的 SHA-1
find_identity() {
    local hash name
    while IFS=$'\t' read -r hash name; do
        local team
        team=$(security find-certificate -a -Z -p -c "$name" \
            | awk -v h="$hash" '/^SHA-1 hash:/ {keep = ($3 == h); next} keep && /BEGIN/ {p = 1} p {print} /END/ {p = 0}' \
            | openssl x509 -noout -subject 2>/dev/null \
            | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$')
        if [[ "$team" == "$TEAM_ID" ]]; then
            echo "$hash"
            return
        fi
    done < <(security find-identity -v -p codesigning \
        | awk -F'"' -v kind="$1" '$2 ~ kind {split($1, f, " "); print f[2] "\t" $2}')
}

IDENTITY="${FAYMEE_SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
if [[ -z "$IDENTITY" ]]; then
    echo "未找到团队 $TEAM_ID 的 Apple Development 证书。没有稳定签名时，每次重新构建系统都会重新询问麦克风权限" >&2
    exit 1
fi

ARCH=$(uname -m)
echo "==> 编译 Faymee（${ARCH}）"
swift build -c release --arch "$ARCH"
BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Faymee" "$APP/Contents/MacOS/Faymee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

echo "==> 签名"
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/Faymee.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> 构建完成：$APP"

if [[ "$MODE" == "install" ]]; then
    DEST=/Applications/Faymee.app
    osascript -e 'tell application id "com.faymee.app" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
        pgrep -x Faymee >/dev/null || break
        sleep 0.2
    done
    pkill -x Faymee 2>/dev/null || true
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    open "$DEST"
    echo "==> 已安装并启动：$DEST"
fi
