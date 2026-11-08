#!/usr/bin/env bash
#
# obs-nvenc-legacy — 卸载: 恢复发行版原始模块, 移除钩子与辅助文件
#
set -euo pipefail

VERSION="1.0.0"
WORKDIR="${XDG_CACHE_HOME:-$HOME/.cache}/obs-nvenc-legacy"
PURGE=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	cat <<EOF
obs-nvenc-legacy $VERSION — 卸载 / 还原

用法: ./uninstall.sh [--purge]

  --purge   同时删除源码与构建缓存 ($WORKDIR)
  -h        显示帮助
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--purge)  PURGE=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) die "未知选项: $1 (用 -h 查看帮助)" ;;
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

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

cat > "$TMP" <<'EOF'
set -e
STATE_DIR=/var/lib/obs-nvenc-legacy
SHARE_DIR=/usr/local/share/obs-nvenc-legacy
HELPER=/usr/local/bin/obs-nvenc-legacy-reinstall
BOOTSTRAP=/usr/local/bin/obs-nvenc-legacy
HOOK=/etc/pacman.d/hooks/99-obs-nvenc-legacy.hook
SO_TARGET=/usr/lib/obs-modules/core/obs-nvenc.so
TEST_TARGET=/usr/bin/obs-nvenc-test

if [ -f "$STATE_DIR/backup/obs-nvenc.so.orig" ]; then
	install -Dm755 "$STATE_DIR/backup/obs-nvenc.so.orig" "$SO_TARGET"
	echo "已还原 $SO_TARGET"
else
	echo "[!] 没有备份 $SO_TARGET, 如需还原请重装 obs-studio 包"
fi

if [ -f "$STATE_DIR/backup/obs-nvenc-test.orig" ]; then
	install -Dm755 "$STATE_DIR/backup/obs-nvenc-test.orig" "$TEST_TARGET"
	echo "已还原 $TEST_TARGET"
else
	echo "[!] 没有备份 $TEST_TARGET"
fi

rm -f "$HOOK" "$HELPER" "$BOOTSTRAP"
rm -rf "$SHARE_DIR" "$STATE_DIR"
echo "已移除钩子与辅助文件"
EOF

log "还原系统文件 (需要 root)"
as_root sh "$TMP"

if [ "$PURGE" -eq 1 ]; then
	log "删除缓存 $WORKDIR"
	rm -rf "$WORKDIR"
fi

log "卸载完成。重启 OBS 使改动生效。"
