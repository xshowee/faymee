#!/bin/bash
# 下载静音切段模型 silero_vad.onnx 到 Resources/VAD/（被 git 忽略，build.sh 打包时拷进 App，契约测试也从这里找）。
#   scripts/fetch-vad-model.sh [目标目录]
# 已有且 sha256 对得上时不重新下载；下载的文件校验不过就报错退出，不留半截文件。
# 文件名与 Sources/FaymeeCore/ModelCatalog.swift 里 Silero VAD 目录项（`.bundled(directory: "VAD", ...)`）保持一致
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="${1:-Resources/VAD}"
mkdir -p "$DEST"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# FAYMEE_VAD_MIRROR：替换下载地址前缀（目录结构同 GitHub release：<tag>/<文件名>），如内网镜像或 file:// 本地目录
RELEASES=${FAYMEE_VAD_MIRROR:-https://github.com/k2-fsa/sherpa-onnx/releases/download}

# sherpa-onnx 转存的 Silero VAD（asr-models/silero_vad.onnx，643854 字节；评估用的就是这个文件）
VAD_URL=$RELEASES/asr-models/silero_vad.onnx
VAD_FILE=silero_vad.onnx
VAD_SHA=9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6
VAD_LICENSE=silero-vad.LICENSE

sha_ok() { [[ -f "$1" && "$(shasum -a 256 "$1" | cut -d' ' -f1)" == "$2" ]]; }

if ! sha_ok "$DEST/$VAD_FILE" "$VAD_SHA"; then
    echo "==> 下载静音切段模型"
    curl -fL --retry 3 -o "$WORK/vad.onnx" "$VAD_URL"
    if ! sha_ok "$WORK/vad.onnx" "$VAD_SHA"; then
        echo "校验失败：$VAD_URL 的 sha256 不是 $VAD_SHA" >&2
        exit 1
    fi
    mv "$WORK/vad.onnx" "$DEST/$VAD_FILE"
fi

cat > "$DEST/$VAD_LICENSE" <<'NOTICE'
silero_vad.onnx
来源：Silero VAD（https://github.com/snakers4/silero-vad），
sherpa-onnx 转存：https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models
许可证：MIT License，Copyright (c) 2020-present Silero Team
NOTICE

echo "==> 静音切段模型就绪：$DEST"
