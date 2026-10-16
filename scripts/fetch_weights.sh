#!/usr/bin/env bash
set -euo pipefail

WORK="${1:-work}"
mkdir -p "$WORK" THIRD_PARTY

LUT_REPO="https://raw.githubusercontent.com/HuiZeng/Image-Adaptive-3DLUT/b491f6df64a588864739a157db271e5c848e1805"
curl -fsSL -o "$WORK/classifier.pth" "$LUT_REPO/pretrained_models/sRGB/classifier.pth"
curl -fsSL -o "$WORK/LUTs.pth" "$LUT_REPO/pretrained_models/sRGB/LUTs.pth"
curl -fsSL -o "THIRD_PARTY/Image-Adaptive-3DLUT-LICENSE.txt" "$LUT_REPO/LICENSE"

GAIC_REPO="https://raw.githubusercontent.com/lld533/Grid-Anchor-based-Image-Cropping-Pytorch/f6f925dadaf3c975f84c422ad575e0c92dc87320"
mkdir -p "$WORK/gaic"
curl -fsSL -o "$WORK/gaic.pth" "$GAIC_REPO/pretrained_model/mobilenet_0.625_0.583_0.553_0.525_0.785_0.762_0.748_0.723_0.783_0.806.pth"
curl -fsSL -o "$WORK/gaic/mobilenetv2.py" "$GAIC_REPO/mobilenetv2.py"
curl -fsSL -o "THIRD_PARTY/GAIC-LICENSE.txt" "$GAIC_REPO/LICENSE"

ls -la "$WORK"
