#!/bin/bash
# 构建 Faymee.app
#   ./build.sh            开发构建（Apple Development 签名，本机架构）→ build/Faymee.app
#   ./build.sh install    开发构建并安装到 /Applications/Faymee.app，然后启动
#
# 环境变量（也可以写在仓库根目录的 .env 里，格式见 .env.example；命令行里设置的优先）：
#   FAYMEE_TEAM_ID        签名所属团队（证书名末尾括号里的 10 位 ID）。不填时取钥匙串里唯一团队的证书；
#                         麦克风授权跟签名绑定，换团队后系统会重新询问权限
#   FAYMEE_SIGN_IDENTITY  开发签名证书（名称或 SHA-1），默认取该团队的 Apple Development 证书
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
BUILD="$ROOT/build"
APP="$BUILD/Faymee.app"
MODE="${1:-dev}"

# load_env_file：读取 .env 里的 FAYMEE_* 变量（只认 NAME=值 这样的行，值两边的引号会去掉），
# 不执行其中的命令；值为空的行当作没写，已经设置的环境变量不覆盖。
load_env_file() {
    local line name value
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^(FAYMEE_[A-Z_]+)=(.*)$ ]] || continue
        name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then
            value=${value:1:${#value}-2}
        fi
        if [[ -n "$value" && -z "${!name:-}" ]]; then
            export "$name=$value"
        fi
    done < "$1"
}
if [[ -f .env ]]; then
    load_env_file .env
fi
TEAM_ID="${FAYMEE_TEAM_ID:-}"

# list_identities <证书类型>：每行输出该类型一个有效证书的“SHA-1<Tab>团队 ID”
list_identities() {
    local hash name team
    while IFS=$'\t' read -r hash name; do
        team=$(security find-certificate -a -Z -p -c "$name" \
            | awk -v h="$hash" '/^SHA-1 hash:/ {keep = ($3 == h); next} keep && /BEGIN/ {p = 1} p {print} /END/ {p = 0}' \
            | openssl x509 -noout -subject 2>/dev/null \
            | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' || true)
        printf '%s\t%s\n' "$hash" "$team"
    done < <(security find-identity -v -p codesigning \
        | awk -F'"' -v kind="$1" '$2 ~ kind {split($1, f, " "); print f[2] "\t" $2}')
}

# find_identity <证书类型>：输出 TEAM_ID 团队下该类型第一个证书的 SHA-1；
# 没指定团队时，钥匙串里只有一个团队就用它，有多个则报错要求指定
find_identity() {
    local identities teams
    identities=$(list_identities "$1")
    if [[ -z "$TEAM_ID" ]]; then
        teams=$(cut -f2 <<<"$identities" | sort -u | grep -v '^$' || true)
        if [[ $(grep -c . <<<"$teams") -gt 1 ]]; then
            echo "钥匙串里有多个团队的 $1 证书：$(tr '\n' ' ' <<<"$teams")" >&2
            echo "请在 .env 里设置 FAYMEE_TEAM_ID（参考 .env.example）" >&2
            exit 1
        fi
        TEAM_ID=$teams
    fi
    awk -F'\t' -v t="$TEAM_ID" '$2 == t {print $1; exit}' <<<"$identities"
}

IDENTITY="${FAYMEE_SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
if [[ -z "$IDENTITY" ]]; then
    echo "未找到${TEAM_ID:+团队 $TEAM_ID 的} Apple Development 证书。没有稳定签名时，每次重新构建系统都会重新询问麦克风权限" >&2
    exit 1
fi

# 区分说话人模型（约 34MB，不进 git）：没有或校验不过时下载
./scripts/fetch-diarization-models.sh Resources/Diarization

ARCH=$(uname -m)
echo "==> 编译 Faymee（${ARCH}）"
swift build -c release --arch "$ARCH"
BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Faymee" "$APP/Contents/MacOS/Faymee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 数据文件不用单独签，随 App 签名封进 CodeResources；sherpa-onnx 是静态链接，不用拷 framework
mkdir -p "$APP/Contents/Resources/Diarization"
cp Resources/Diarization/*.onnx Resources/Diarization/*.LICENSE "$APP/Contents/Resources/Diarization/"
# llama.cpp 是动态 framework：拷进 Contents/Frameworks（ditto 保留 Versions/Current 等符号链接，
# 不拷 llama.dSYM），release 可执行文件的 rpath 只有 @loader_path，要补一条。
# install_name_tool 会让签名失效，必须在签名之前
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/llama.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Faymee"

echo "==> 签名"
# 从里往外签：framework 自带 ad-hoc 签名，hardened runtime 的 library validation 要求它和 App
# 同一团队，否则 dyld 拒绝加载
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" \
    "$APP/Contents/Frameworks/llama.framework"
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
