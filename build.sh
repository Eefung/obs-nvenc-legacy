#!/usr/bin/env bash
#
# obs-nvenc-legacy — 为 Maxwell / Pascal / Volta 显卡重建 OBS 的 NVENC 模块
#
# 问题: OBS 33 与 ffmpeg 9 使用 nv-codec-headers 13.1 编译, 运行时要求 NVIDIA
#       驱动 >= 610 (NVENC API 13.1)。而 Maxwell / Pascal / Volta 的最后一个
#       驱动分支 580xx 只提供 NVENC API 13.0, 于是 OBS 启动时报
#           [NVENC] Test process failed: outdated_driver
#       并禁用全部 NVIDIA 编码器 (obs-nvenc.so 初始化失败)。
#
# 做法: 用与本机驱动匹配版本的 nv-codec-headers 重新编译 OBS 33 的 obs-nvenc
#       插件 (obs-nvenc.so + obs-nvenc-test), 只替换这两个文件, 不动 OBS 本体,
#       不动驱动; 并安装 pacman 钩子, 使 OBS 升级后自动恢复。
#
# 用法: ./build.sh [选项]
# 详见 -h。
set -euo pipefail

VERSION="1.0.0"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OBS_VERSION=""
NVENC_API=""
WORKDIR="${XDG_CACHE_HOME:-$HOME/.cache}/obs-nvenc-legacy"
DO_INSTALL=1
DO_HOOK=1
FORCE=0

STATE_DIR=/var/lib/obs-nvenc-legacy
SHARE_DIR=/usr/local/share/obs-nvenc-legacy
HELPER=/usr/local/bin/obs-nvenc-legacy-reinstall
BOOTSTRAP=/usr/local/bin/obs-nvenc-legacy
HOOK=/etc/pacman.d/hooks/99-obs-nvenc-legacy.hook
SO_TARGET=/usr/lib/obs-modules/core/obs-nvenc.so
TEST_TARGET=/usr/bin/obs-nvenc-test
OBS_UPSTREAM=https://github.com/obsproject/obs-studio
NVCH_UPSTREAM=https://github.com/FFmpeg/nv-codec-headers

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
obs-nvenc-legacy $VERSION — 让 OBS 在老 NVIDIA 显卡上重新用上 NVENC

用法: ./build.sh [选项]

选项:
  --obs-version <VER>   指定 OBS 版本 (默认取 pkg-config libobs 的版本)
  --api <MAJOR.MINOR>   指定要使用的 NVENC API 版本 (默认取驱动能支持的最高版本)
  --workdir <DIR>       源码与构建目录 (默认 \${XDG_CACHE_HOME:-~/.cache}/obs-nvenc-legacy)
  --no-install          只编译, 不安装
  --no-hook             不安装 pacman 钩子 (OBS 升级后需要手动重跑)
  --force               即使当前 NVENC 已可用 / 已有构建也重新编译
  -h, --help            显示本帮助

示例:
  ./build.sh                          # 自动检测并修复
  ./build.sh --force --no-hook        # 强制重编, 不装钩子
  ./build.sh --api 13.0 --obs-version 33.0.1

退出码: 0 成功, 1 失败
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--obs-version) OBS_VERSION="${2:-}"; shift 2 ;;
		--api)         NVENC_API="${2:-}";   shift 2 ;;
		--workdir)     WORKDIR="${2:-}";     shift 2 ;;
		--no-install)  DO_INSTALL=0;         shift ;;
		--no-hook)     DO_HOOK=0;            shift ;;
		--force|--rebuild) FORCE=1;           shift ;;
		-h|--help)     usage; exit 0 ;;
		*)             die "未知选项: $1 (用 -h 查看帮助)" ;;
	esac
done

as_root() {
	if [ "$(id -u)" -eq 0 ]; then
		"$@"
	elif sudo -n true 2>/dev/null; then
		sudo "$@"
	elif [ -t 0 ] && command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	elif command -v pkexec >/dev/null 2>&1; then
		pkexec "$@"
	elif command -v sudo >/dev/null 2>&1; then
		sudo "$@"
	else
		die "需要 root 权限, 但系统里没有 sudo / pkexec"
	fi
}

# ---------------------------------------------------------------- 检测 ----

detect_obs_version() {
	local v
	v=$(pkg-config --modversion libobs 2>/dev/null || true)
	[ -n "$v" ] || die "未检测到 OBS (缺少 libobs 开发信息)。请先安装 obs-studio。"
	printf '%s\n' "$v"
}

# 驱动支持的最高 NVENC API 版本, 例如 "13.0"
driver_api() {
	local out=""
	if [ -x "$TEST_TARGET" ]; then
		out=$("$TEST_TARGET" 2>/dev/null | sed -n 's/^nvenc_ver=//p' | head -n1 || true)
	fi
	if [ -z "$out" ]; then
		out=$(python3 - <<'PY' 2>/dev/null || true
import ctypes
lib = ctypes.CDLL("libnvidia-encode.so.1")
ver = ctypes.c_uint()
if lib.NvEncodeAPIGetMaxSupportedVersion(ctypes.byref(ver)) != 0:
    raise SystemExit(1)
print(f"{ver.value >> 4}.{ver.value & 0xf}")
PY
		)
	fi
	[ -n "$out" ] || die "读不到驱动的 NVENC API 版本 (驱动没加载? 试试 nvidia-smi)"
	printf '%s\n' "$out"
}

# NVENC API -> nv-codec-headers tag
tag_for_api() {
	case "$1" in
		13.1) echo "n13.1.15.0" ;;
		13.0) echo "n13.0.19.1" ;;
		12.2) echo "n12.2.72.0" ;;
		12.1) echo "n12.1.14.1" ;;
		12.0) echo "n12.0.16.2" ;;
		*) return 1 ;;
	esac
}

# 当前发行版模块是否已经能用
current_ok() {
	[ -x "$TEST_TARGET" ] || return 1
	"$TEST_TARGET" 2>/dev/null | grep -qx 'nvenc_supported=true'
}

for tool in git gcc g++ pkg-config; do
	command -v "$tool" >/dev/null 2>&1 || die "缺少依赖: $tool"
done

[ -n "$OBS_VERSION" ] || OBS_VERSION=$(detect_obs_version)
[ -n "$NVENC_API" ]   || NVENC_API=$(driver_api)
NVCH_TAG=$(tag_for_api "$NVENC_API") || die "驱动 NVENC API $NVENC_API 没有对应的 nv-codec-headers 版本"

log "OBS 版本:        $OBS_VERSION"
log "驱动 NVENC API:  $NVENC_API  (nv-codec-headers $NVCH_TAG)"

if [ "$FORCE" -eq 0 ] && current_ok; then
	log "当前 NVENC 已经可用, 无需修复。要强制重建请加 --force"
	exit 0
fi

# ---------------------------------------------------------------- 源码 ----

SRC="$WORKDIR/obs-studio-$OBS_VERSION"
NVCH="$WORKDIR/nv-codec-headers-$NVCH_TAG"
BUILD="$WORKDIR/build-$OBS_VERSION-$NVENC_API"

fetch_sources() {
	mkdir -p "$WORKDIR"
	if [ ! -d "$SRC/.git" ]; then
		log "获取 OBS $OBS_VERSION 源码"
		git -c advice.detachedHead=false clone -q --depth 1 --branch "$OBS_VERSION" \
			--filter=blob:none --sparse "$OBS_UPSTREAM" "$SRC" 2>&1 | grep -v "不是一个提交" || true
		git -C "$SRC" sparse-checkout set \
			plugins/obs-nvenc shared/opts-parser deps/glad >/dev/null
	elif [ "$FORCE" -eq 1 ]; then
		git -C "$SRC" fetch -q --depth 1 origin "refs/tags/$OBS_VERSION:refs/tags/$OBS_VERSION" || true
	fi

	if [ ! -d "$NVCH" ]; then
		log "获取 nv-codec-headers $NVCH_TAG"
		git -c advice.detachedHead=false clone -q --depth 1 --branch "$NVCH_TAG" \
			"$NVCH_UPSTREAM" "$NVCH" 2>&1 | grep -v "不是一个提交" || true
	fi
}

build_module() {
	mkdir -p "$BUILD"
	local incs cflags
	incs="-I/usr/include/obs \
		-I$SRC/plugins/obs-nvenc \
		-I$SRC/shared/opts-parser \
		-I$SRC/deps/glad/include \
		-I$NVCH/include"
	cflags="$(pkg-config --cflags libobs) -O2 -fPIC -w -DREGISTER_FFMPEG_IDS -DENABLE_HEVC $incs"

	log "编译 obs-nvenc.so (NVENC API $NVENC_API)"
	(
		cd "$SRC"
		# shellcheck disable=SC2086
		gcc $cflags -shared -o "$BUILD/obs-nvenc.so" \
			plugins/obs-nvenc/nvenc.c \
			plugins/obs-nvenc/obs-nvenc.c \
			plugins/obs-nvenc/nvenc-compat.c \
			plugins/obs-nvenc/nvenc-cuda.c \
			plugins/obs-nvenc/nvenc-helpers.c \
			plugins/obs-nvenc/nvenc-opengl.c \
			plugins/obs-nvenc/nvenc-opts-parser.c \
			plugins/obs-nvenc/nvenc-properties.c \
			plugins/obs-nvenc/cuda-helpers.c \
			shared/opts-parser/opts-parser.c \
			deps/glad/src/glad.c \
			deps/glad/src/glad_egl.c \
			-L/usr/lib -lobs -lavcodec -lavutil -lGL -lEGL -ldl -lm

		log "编译 obs-nvenc-test"
		g++ -O2 -w -I"$NVCH/include" -o "$BUILD/obs-nvenc-test" \
			plugins/obs-nvenc/obs-nvenc-test/obs-nvenc-test.cpp -ldl
	)
}

verify_build() {
	local out
	out=$("$BUILD/obs-nvenc-test" 2>/dev/null || true)
	printf '%s\n' "$out" | grep -qx 'nvenc_supported=true' \
		|| die "构建产物自检失败, 输出如下:
$out"

	local ver h264 hevc
	ver=$(printf '%s\n' "$out" | sed -n 's/^nvenc_ver=//p')
	h264=$(printf '%s\n' "$out" | sed -n '/^\[h264\]/,/^\[/s/^codec_supported=//p' | head -n1)
	hevc=$(printf '%s\n' "$out" | sed -n '/^\[hevc\]/,/^\[/s/^codec_supported=//p' | head -n1)
	[ "$h264" = "1" ] || warn "H.264 未被驱动报告为可用"
	log "自检通过: NVENC API $ver, H.264=$h264 HEVC=${hevc:-0}"
}

# ---------------------------------------------------------------- 安装 ----

install_files() {
	local step="$WORKDIR/install-step.sh" hook_block=""

	cat > "$WORKDIR/install.info" <<EOF
obs_version=$OBS_VERSION
nvenc_api=$NVENC_API
nv-codec-headers=$NVCH_TAG
built_at=$(date -Is)
EOF

	if [ "$DO_HOOK" -eq 1 ]; then
		cat > "$WORKDIR/99-obs-nvenc-legacy.hook" <<EOF
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = obs-studio
Target = obs-studio-browser
Target = obs-studio-git

[Action]
Description = Restoring obs-nvenc built against NVENC API $NVENC_API (obs-nvenc-legacy)...
When = PostTransaction
Exec = $HELPER
EOF
		hook_block="install -Dm644 '$WORKDIR/99-obs-nvenc-legacy.hook' '$HOOK'"
	fi

	cat > "$step" <<EOF
set -e
mkdir -p '$STATE_DIR/backup' '$SHARE_DIR'

# 只在第一次安装时备份发行版原件, 重装不会用已打补丁的版本覆盖备份
if [ -f '$SO_TARGET' ] && [ ! -f '$STATE_DIR/backup/obs-nvenc.so.orig' ]; then
	cp -a '$SO_TARGET' '$STATE_DIR/backup/obs-nvenc.so.orig'
fi
if [ -f '$TEST_TARGET' ] && [ ! -f '$STATE_DIR/backup/obs-nvenc-test.orig' ]; then
	cp -a '$TEST_TARGET' '$STATE_DIR/backup/obs-nvenc-test.orig'
fi

install -Dm755 '$BUILD/obs-nvenc.so'   '$SO_TARGET'
install -Dm755 '$BUILD/obs-nvenc-test' '$TEST_TARGET'
install -Dm755 '$BUILD/obs-nvenc.so'   '$SHARE_DIR/obs-nvenc.so'
install -Dm755 '$BUILD/obs-nvenc-test' '$SHARE_DIR/obs-nvenc-test'
install -Dm755 '$REPO_DIR/files/reinstall.sh' '$HELPER'
install -Dm755 '$REPO_DIR/build.sh' '$BOOTSTRAP'
install -Dm644 '$WORKDIR/install.info' '$STATE_DIR/install.info'
$hook_block
EOF

	log "安装到 $SO_TARGET 与 $TEST_TARGET (需要 root)"
	as_root sh "$step"
}

installed_ok() {
	[ -x "$TEST_TARGET" ] && "$TEST_TARGET" 2>/dev/null | grep -qx 'nvenc_supported=true'
}

# ---------------------------------------------------------------- 主流程 ----

fetch_sources
if [ "$FORCE" -eq 0 ] && [ -x "$BUILD/obs-nvenc.so" ] && [ -x "$BUILD/obs-nvenc-test" ]; then
	log "复用已有构建: $BUILD"
else
	build_module
fi
verify_build

if [ "$DO_INSTALL" -eq 0 ]; then
	log "已按 --no-install 跳过安装。产物: $BUILD"
	exit 0
fi

install_files
installed_ok || die "安装后自检失败, 请查看 $TEST_TARGET 的输出"

cat <<EOF

$(printf '\033[1;32m✔\033[0m') 完成。重启 OBS 后 "设置 → 输出" 里应能看到:
   - NVIDIA NVENC H.264
   - NVIDIA NVENC HEVC   (若显卡支持)

   模块位置: $SO_TARGET
   原件备份: $STATE_DIR/backup/
   重新安装: $BOOTSTRAP            (改为 --rebuild 可重新编译)
   卸载还原: $REPO_DIR/uninstall.sh

   注意: OBS 日志里出现 "Not running on NVIDIA GPU, falling back to
   non-texture encoder" 属正常 (OBS 用核显渲染, NVENC 走 CUDA 拷贝路径),
   仍然是硬件编码。
EOF
