#!/bin/bash
# 下载区分说话人的模型到 Resources/Diarization/（被 git 忽略，build.sh 打包时拷进 App，契约测试也从这里找）。
#   scripts/fetch-diarization-models.sh [目标目录]
# 已有且 sha256 对得上的文件不重新下载；下载的文件校验不过就报错退出，不留半截文件。
# 文件名、sha256 与 Sources/FaymeeCore/SherpaOnnxDiarizer.swift 里的 `SherpaOnnxDiarizer.models` 保持一致：
# App 在 prepare 时还会再校验一遍（坏模型会让 sherpa-onnx 直接 _Exit 整个进程）
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="${1:-Resources/Diarization}"
mkdir -p "$DEST"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# FAYMEE_DIARIZATION_MIRROR：替换下载地址前缀（目录结构同 GitHub release：<tag>/<文件名>），如内网镜像或 file:// 本地目录
RELEASES=${FAYMEE_DIARIZATION_MIRROR:-https://github.com/k2-fsa/sherpa-onnx/releases/download}

# 声纹：3D-Speaker ERes2Net base 中文模型（Apache-2.0，ModelScope iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k，
# 3D-Speaker 数据集训练）。sha256 与 release 里的 checksum.txt 一致。注意 tag 拼写就是 recongition
EMB_URL=$RELEASES/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
EMB_FILE=3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
EMB_SHA=1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b
EMB_LICENSE=3dspeaker-eres2net-base.LICENSE

sha_ok() { [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]; }

# check <文件> <sha256>：校验通过返回 0，否则报错退出
check() {
    if ! sha_ok "$1" "$2"; then
        echo "校验失败：$1 的 sha256 不是 $2" >&2
        exit 1
    fi
}

if ! sha_ok "$DEST/$EMB_FILE" "$EMB_SHA"; then
    echo "==> 下载声纹模型"
    curl -fL --retry 3 -o "$WORK/emb.onnx" "$EMB_URL"
    check "$WORK/emb.onnx" "$EMB_SHA"
    mv "$WORK/emb.onnx" "$DEST/$EMB_FILE"
fi

cat > "$DEST/$EMB_LICENSE" <<'NOTICE'
3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx
来源：ModelScope iic/speech_eres2net_base_sv_zh-cn_3dspeaker_16k（3D-Speaker，阿里巴巴通义实验室），
sherpa-onnx 转换版：https://github.com/k2-fsa/sherpa-onnx/releases/tag/speaker-recongition-models
许可证：Apache License 2.0，https://www.apache.org/licenses/LICENSE-2.0
NOTICE

echo "==> 区分说话人模型就绪：$DEST"
