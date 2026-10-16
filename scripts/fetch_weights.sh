#!/usr/bin/env bash
set -euo pipefail

WORK="${1:-work}"
mkdir -p "$WORK" THIRD_PARTY

LUT_REPO="https://raw.githubusercontent.com/HuiZeng/Image-Adaptive-3DLUT/b491f6df64a588864739a157db271e5c848e1805"
curl -fsSL -o "$WORK/classifier.pth" "$LUT_REPO/pretrained_models/sRGB/classifier.pth"
curl -fsSL -o "$WORK/LUTs.pth" "$LUT_REPO/pretrained_models/sRGB/LUTs.pth"
curl -fsSL -o "THIRD_PARTY/Image-Adaptive-3DLUT-LICENSE.txt" "$LUT_REPO/LICENSE"

ls -la "$WORK"
