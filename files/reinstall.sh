#!/bin/sh
# 由 pacman 钩子在 obs-studio 升级后调用 (以 root 身份运行):
# 把 obs-nvenc-legacy 预先构建好的 NVENC 模块放回发行版位置。
set -e

SHARE_DIR=/usr/local/share/obs-nvenc-legacy
SO_TARGET=/usr/lib/obs-modules/core/obs-nvenc.so
TEST_TARGET=/usr/bin/obs-nvenc-test

[ -f "$SHARE_DIR/obs-nvenc.so" ] || exit 0
[ -f "$SHARE_DIR/obs-nvenc-test" ] || exit 0

install -m755 "$SHARE_DIR/obs-nvenc.so" "$SO_TARGET"
install -m755 "$SHARE_DIR/obs-nvenc-test" "$TEST_TARGET"

echo "obs-nvenc-legacy: 已恢复按 NVENC API 13.0 编译的 obs-nvenc 模块"
