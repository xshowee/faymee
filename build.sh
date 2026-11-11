#!/bin/bash
# 构建 Faymee.app
#   ./build.sh            开发构建（Apple Development 签名，本机架构）→ build/Faymee.app
#   ./build.sh install    开发构建并安装到 /Applications/Faymee.app，然后启动
#   ./build.sh release    发布构建（Developer ID 签名、公证，仅 Apple Silicon）→ build/release/ 下的
#                         Faymee-<版本>.dmg 和 appcast.xml，上传到 GitHub Release 的方法见结尾输出。
#                         版本号取 Resources/Info.plist；发布说明取 docs/releases/<版本>.md
#
# 开发构建不写 SUFeedURL，App 里的自动更新不启用；只有发布构建会检查更新。
#
# 环境变量（也可以写在仓库根目录的 .env 里，格式见 .env.example；命令行里设置的优先）：
#   FAYMEE_TEAM_ID        签名所属团队（证书名末尾括号里的 10 位 ID）。不填时取钥匙串里唯一团队的证书；
#                         麦克风授权跟签名绑定，换团队后系统会重新询问权限
#   FAYMEE_SIGN_IDENTITY  开发签名证书（名称或 SHA-1），默认取该团队的 Apple Development 证书
#   FAYMEE_RELEASE_IDENTITY  发布签名证书，默认取该团队的 Developer ID Application 证书
#   FAYMEE_NOTARY_PROFILE 公证凭据在钥匙串里的名字（xcrun notarytool store-credentials 时起的），
#                         默认 faymee-notary
#   FAYMEE_NOTARIZE       设为 0 时发布构建跳过公证（只用于本机测试升级，产物不能发给别人）
#   FAYMEE_FEED_URL       发布构建写进 App 的更新地址，默认 GitHub 上最新 Release 的 appcast.xml；
#                         FAYMEE_DOWNLOAD_URL 是 appcast 里安装包所在的目录。两者只在本机测试升级时改
set -euo pipefail

cd "$(dirname "$0")"
ROOT=$(pwd)
BUILD="$ROOT/build"
APP="$BUILD/Faymee.app"
MODE="${1:-dev}"
case "$MODE" in
    dev | install | release) ;;
    *) echo "用法：./build.sh [install | release]" >&2; exit 1 ;;
esac
REPO_URL=https://github.com/xshowee/faymee
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
# 更新包签名用的 EdDSA 私钥在钥匙串里的名字（generate_keys --account faymee 生成）；
# 公钥写在 Info.plist 的 SUPublicEDKey。私钥丢了就再也发不了更新，导出备份见 generate_keys -x
SPARKLE_ACCOUNT=faymee

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

if [[ "$MODE" == "release" ]]; then
    IDENTITY="${FAYMEE_RELEASE_IDENTITY:-$(find_identity 'Developer ID Application')}"
    if [[ -z "$IDENTITY" ]]; then
        echo "未找到${TEAM_ID:+团队 $TEAM_ID 的} Developer ID Application 证书，发布构建必须用它签名" >&2
        exit 1
    fi
    NOTARIZE="${FAYMEE_NOTARIZE:-1}"
    NOTARY_PROFILE="${FAYMEE_NOTARY_PROFILE:-faymee-notary}"
    if [[ "$NOTARIZE" != 0 && -n "$(git status --porcelain)" ]]; then
        echo "工作区有未提交的改动。正式发布要从提交过的代码构建，先提交或暂存" >&2
        exit 1
    fi
    VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)
    NOTES="docs/releases/$VERSION.md"
    if [[ ! -f "$NOTES" ]]; then
        echo "缺少发布说明 $NOTES（会显示在更新窗口和 GitHub Release 里）" >&2
        exit 1
    fi
    FEED_URL="${FAYMEE_FEED_URL:-$REPO_URL/releases/latest/download/appcast.xml}"
    DOWNLOAD_URL="${FAYMEE_DOWNLOAD_URL:-$REPO_URL/releases/download/v$VERSION}"
    # 发布版只支持 Apple Silicon
    ARCH=arm64
    TIMESTAMP=--timestamp
else
    IDENTITY="${FAYMEE_SIGN_IDENTITY:-$(find_identity 'Apple Development')}"
    if [[ -z "$IDENTITY" ]]; then
        echo "未找到${TEAM_ID:+团队 $TEAM_ID 的} Apple Development 证书。没有稳定签名时，每次重新构建系统都会重新询问麦克风权限" >&2
        exit 1
    fi
    ARCH=$(uname -m)
    TIMESTAMP=--timestamp=none
fi

# 区分说话人模型（约 40MB，不进 git）：没有或校验不过时下载
./scripts/fetch-diarization-models.sh Resources/Diarization

echo "==> 编译 Faymee（${ARCH}）"
swift build -c release --arch "$ARCH"
BIN_DIR=$(swift build -c release --arch "$ARCH" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Faymee" "$APP/Contents/MacOS/Faymee"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ "$MODE" == "release" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# 数据文件不用单独签，随 App 签名封进 CodeResources；sherpa-onnx 是静态链接，不用拷 framework
mkdir -p "$APP/Contents/Resources/Diarization"
# 只拷当前引擎用的文件（目录里可能还留着旧引擎的模型）
cp Resources/Diarization/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx \
    Resources/Diarization/3dspeaker-eres2net-base.LICENSE "$APP/Contents/Resources/Diarization/"
# llama.cpp 是动态 framework：拷进 Contents/Frameworks（ditto 保留 Versions/Current 等符号链接，
# 不拷 llama.dSYM），release 可执行文件的 rpath 只有 @loader_path，要补一条。
# install_name_tool 会让签名失效，必须在签名之前
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/llama.framework"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Faymee"

echo "==> 签名"
# 从里往外签：framework 自带 ad-hoc 签名，hardened runtime 的 library validation 要求它和 App
# 同一团队，否则 dyld 拒绝加载
sign() { codesign --force --options runtime "$TIMESTAMP" --sign "$IDENTITY" "$@"; }
sign "$APP/Contents/Frameworks/llama.framework"
# Sparkle 的辅助程序逐个签（Sparkle 文档的做法，不用 --deep）；Downloader 要保留自带的 entitlements
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements Resources/Faymee.entitlements "$APP"
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

# notarize <文件>：提交公证、等结果，通过后把票据钉进文件
notarize() {
    echo "==> 公证 $(basename "$1")（通常几分钟）"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    if [[ "$1" == *.zip ]]; then
        xcrun stapler staple "$APP"
    else
        xcrun stapler staple "$1"
    fi
}

if [[ "$MODE" == "release" ]]; then
    OUT="$BUILD/release"
    DMG="$OUT/Faymee-$VERSION.dmg"
    rm -rf "$OUT"
    mkdir -p "$OUT"

    # 先公证 App 本身，DMG 里装的就是带票据的 App，离线也能打开
    if [[ "$NOTARIZE" != 0 ]]; then
        ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
        notarize "$OUT/notarize.zip"
        rm "$OUT/notarize.zip"
    fi

    echo "==> 打包 DMG"
    STAGE="$OUT/dmg"
    mkdir -p "$STAGE"
    ditto "$APP" "$STAGE/Faymee.app"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -quiet -volname Faymee -srcfolder "$STAGE" -format UDZO -ov "$DMG"
    rm -rf "$STAGE"
    codesign --force "$TIMESTAMP" --sign "$IDENTITY" "$DMG"
    if [[ "$NOTARIZE" != 0 ]]; then
        notarize "$DMG"
    fi

    # 钉票据会改 DMG，所以 EdDSA 签名放在最后。sign_update 输出 sparkle:edSignature="…" length="…"
    echo "==> 生成 appcast.xml"
    ENCLOSURE=$("$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$DMG")
    MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Resources/Info.plist)
    PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
    cat >"$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Faymee</title>
        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
            <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
            <description sparkle:format="markdown"><![CDATA[
$(cat "$NOTES")
]]></description>
            <enclosure url="$DOWNLOAD_URL/$(basename "$DMG")" type="application/octet-stream" $ENCLOSURE />
        </item>
    </channel>
</rss>
XML
    # Info.plist 里开了 SURequireSignedFeed：appcast 本身也要签名，签名嵌在文件末尾
    "$SPARKLE_BIN/sign_update" --account "$SPARKLE_ACCOUNT" "$OUT/appcast.xml"

    echo "==> 发布产物：$OUT"
    ls -lh "$OUT"
    if [[ "$NOTARIZE" == 0 ]]; then
        echo "（未公证，只能在本机测试升级，不要上传）"
    else
        echo "上传到 GitHub Release（tag 要先推到 GitHub）："
        echo "  gh release create v$VERSION --title \"Faymee $VERSION\" --notes-file $NOTES \\"
        echo "      \"$DMG\" \"$OUT/appcast.xml\""
    fi
fi
