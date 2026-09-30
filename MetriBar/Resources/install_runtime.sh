#!/bin/bash
# MetriBar 转写环境一键构建（全步骤留痕，任一步失败立即报出）
set -uo pipefail
S="/Users/$(whoami)/Library/Application Support/MetriBar"
PY_URL="https://registry.npmmirror.com/-/binary/python-build-standalone/20250918/cpython-3.11.13%2B20250918-aarch64-apple-darwin-install_only.tar.gz"
MIRROR="https://pypi.tuna.tsinghua.edu.cn/simple"
log(){ echo "[$(date +%H:%M:%S)] $*"; }
mkdir -p "$S/logs"
if [ ! -x "$S/runtime/bin/python3" ]; then
  log "STEP1 下载Python运行时(19MB npmmirror)"
  curl -fL --retry 3 -o "$S/runtime.tar.gz" "$PY_URL" || { log "FAIL STEP1 下载失败"; exit 1; }
  log "STEP2 解压并改名对齐"
  rm -rf "$S/runtime"; tar -xzf "$S/runtime.tar.gz" -C "$S" || { log "FAIL STEP2 解压失败"; exit 1; }
  [ -d "$S/python" ] && mv "$S/python" "$S/runtime"
  rm -f "$S/runtime.tar.gz"
  [ -x "$S/runtime/bin/python3" ] || { log "FAIL STEP2 python不存在"; exit 1; }
  log "STEP1-2完成 ✓"
else log "STEP1-2 运行已存在跳过"; fi
if [ ! -x "$S/env/bin/python3" ]; then
  log "STEP3 创建venv"
  "$S/runtime/bin/python3" -m venv "$S/env" || { log "FAIL STEP3 venv失败"; exit 1; }
fi
rm -rf "$HOME/Library/Caches/pip"  # macOS真实缓存位置(macOS不在~/.cache/pip)
log "STEP4 安装依赖(9包 清华镜像 无缓存直连)"
P=(funasr==1.4.1 torch torchaudio mlx-lm openai opencc-python-reimplemented soundfile python-multipart librosa)
for i in "${!P[@]}"; do
  log "依赖 $((i+1))/9 ${P[$i]}"
  "$S/env/bin/python3" -m pip install --no-input -q --no-cache-dir --index-url "$MIRROR" "${P[$i]}" || { log "FAIL ${P[$i]}"; exit 1; }
done
log "STEP5 验证导入"
"$S/env/bin/python3" -c "import funasr, torch, mlx_lm, openai, soundfile, opencc" || { log "FAIL import验证"; exit 1; }
log "✓ 环境构建完成"
