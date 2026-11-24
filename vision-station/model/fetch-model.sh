#!/bin/sh
# 拉取 YOLOv8n ONNX 并转换为 RK3566 的 RKNN 模型。
#
# 模型与转换工具都不进仓(仓规:第三方 blob/模型一律由脚本按官方渠道
# 拉取)。产物落在本目录的 ../models/(已被 .gitignore 忽略)。
#
# 流程:
#   1. 从 Rockchip rknn_model_zoo 官方 download_model.sh 指向的文件
#      托管下载 yolov8n.onnx,并校验 SHA-256(下方钉死,2026-11-24 实测)。
#   2. 用 RKNN-Toolkit2(x86 host)转换:python3 convert.py
#      需要 host 装有 rknn-toolkit2,或在官方 toolkit 容器里跑本脚本。
#
# 用法:./fetch-model.sh [目标平台,默认 rk3566]
set -eu
cd "$(dirname "$0")"
TARGET="${1:-rk3566}"
OUT_DIR="../models"
ONNX_URL="https://ftrg.zbox.filez.com/v2/delivery/data/95f00b0fc900458ba134f8b180b3f7a1/examples/yolov8/yolov8n.onnx"
ONNX_SHA256="0c8716701f471067932b797eeb67c8e5db47c693c2557c881d7679ec12e21bc5"

mkdir -p "$OUT_DIR"
ONNX="$OUT_DIR/yolov8n.onnx"
if [ ! -f "$ONNX" ]; then
    echo "下载 yolov8n.onnx ..."
    curl -fL -o "$ONNX" "$ONNX_URL"
fi
echo "校验 SHA-256 ..."
echo "$ONNX_SHA256  $ONNX" | sha256sum -c -

RKNN="$OUT_DIR/yolov8n_${TARGET}.rknn"
if [ -f "$RKNN" ]; then
    echo "已存在 $RKNN,跳过转换(删掉可重转)"
    exit 0
fi
echo "转换 -> $RKNN(需要 rknn-toolkit2)"
python3 convert.py "$ONNX" "$TARGET" "$RKNN"
echo "完成:$RKNN"
