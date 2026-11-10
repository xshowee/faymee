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

# 分段：pyannote segmentation-3.0 的 sherpa-onnx 转换版（MIT，Copyright (c) 2022 CNRS），fp32。
# 上游只发 tar.bz2、没有发布摘要，两个 sha256 都是本机算的
SEG_TARBALL_URL=$RELEASES/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
SEG_TARBALL_SHA=24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488
SEG_FILE=pyannote-segmentation-3-0.onnx
SEG_SHA=220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079

# 声纹：3D-Speaker CAM++ 中文通用模型（Apache-2.0，ModelScope iic/speech_campplus_sv_zh-cn_16k-common）。
# sha256 与 release 里的 checksum.txt 一致。注意 tag 拼写就是 recongition
EMB_URL=$RELEASES/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx
EMB_FILE=3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx
EMB_SHA=f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11

sha_ok() { [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]; }

# check <文件> <sha256>：校验通过返回 0，否则报错退出
check() {
    if ! sha_ok "$1" "$2"; then
        echo "校验失败：$1 的 sha256 不是 $2" >&2
        exit 1
    fi
}

if ! sha_ok "$DEST/$SEG_FILE" "$SEG_SHA"; then
    echo "==> 下载分段模型"
    curl -fL --retry 3 -o "$WORK/seg.tar.bz2" "$SEG_TARBALL_URL"
    check "$WORK/seg.tar.bz2" "$SEG_TARBALL_SHA"
    tar -xjf "$WORK/seg.tar.bz2" -C "$WORK"
    check "$WORK/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$SEG_SHA"
    mv "$WORK/sherpa-onnx-pyannote-segmentation-3-0/LICENSE" "$DEST/pyannote-segmentation-3-0.LICENSE"
    mv "$WORK/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" "$DEST/$SEG_FILE"
fi

if ! sha_ok "$DEST/$EMB_FILE" "$EMB_SHA"; then
    echo "==> 下载声纹模型"
    curl -fL --retry 3 -o "$WORK/emb.onnx" "$EMB_URL"
    check "$WORK/emb.onnx" "$EMB_SHA"
    mv "$WORK/emb.onnx" "$DEST/$EMB_FILE"
fi

echo "==> 区分说话人模型就绪：$DEST"
