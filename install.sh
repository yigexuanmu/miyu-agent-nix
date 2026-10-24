#!/usr/bin/env bash
# miyu-agent-nix 免编译安装脚本
#
# 下载 CI 构建并签名的二进制缓存（GitHub Releases），配置为本地 Nix
# substituter，然后从缓存安装 miyu —— 全程不编译 Rust。
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/yigexuanmu/miyu-agent-nix/main/install.sh | bash
# 环境变量：
#   MIYU_CACHE_DIR  缓存解压目录（默认 ~/.cache/miyu-nix-cache）
set -euo pipefail

REPO="yigexuanmu/miyu-agent-nix"
CACHE_DIR="${MIYU_CACHE_DIR:-$HOME/.cache/miyu-nix-cache}"
KEY_NAME="miyu-agent-nix-1"
PUB_KEY="4hk2EYv/cb00ccSkWL9snAoB92l/15PGuiS8qlYMcBQ="

command -v curl >/dev/null || { echo "需要 curl"; exit 1; }
command -v nix >/dev/null || { echo "未检测到 Nix，请先安装：https://nixos.org/download"; exit 1; }
command -v zstd >/dev/null || { echo "需要 zstd（解压缓存包用），请先安装"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 下载二进制缓存（release: latest）"
curl -fL "https://github.com/$REPO/releases/latest/download/miyu-binary-cache-x86_64-linux.tar.zst" -o "$TMP/cache.tar.zst"
curl -fsSL "https://github.com/$REPO/releases/latest/download/SHA256SUMS" -o "$TMP/SHA256SUMS"
(cd "$TMP" && sha256sum -c SHA256SUMS)

echo "==> 解压到 $CACHE_DIR"
mkdir -p "$CACHE_DIR"
tar -xf "$TMP/cache.tar.zst" -C "$TMP"
cp -a "$TMP/cache/." "$CACHE_DIR/"

CONF="${XDG_CONFIG_HOME:-$HOME/.config}/nix/nix.conf"
mkdir -p "$(dirname "$CONF")"
touch "$CONF"
if grep -q "miyu-nix-cache" "$CONF" 2>/dev/null; then
  echo "==> nix.conf 已有 miyu 缓存配置，跳过（如缓存路径变过请手动更新）"
else
  cat >> "$CONF" <<EOF

# miyu-agent-nix 本地二进制缓存 (install.sh)
extra-substituters = file://$CACHE_DIR
extra-trusted-public-keys = $KEY_NAME:$PUB_KEY
EOF
  echo "==> 已写入 $CONF"
fi

echo "==> 安装 miyu（从缓存拉取，免编译）"
NIX_EXPERIMENTAL=(--experimental-features 'nix-command flakes')
if "$NIX" profile list 2>/dev/null | grep -q 'github:yigexuanmu/miyu-agent-nix'; then
  echo "==> 已安装过，更新"
  "$NIX" profile remove miyu
fi
"$NIX" "${NIX_EXPERIMENTAL[@]}" profile install "github:$REPO#default"

echo
echo "==> 完成：$("$NIX" profile list 2>/dev/null | grep -o 'miyu.*' | head -1 || true)"
echo "    试试：miyu --version ；初始化：miyu init"
