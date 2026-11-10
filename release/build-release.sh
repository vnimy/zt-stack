#!/usr/bin/env bash
# 打一个「服务器不装源码、不编译」的发布包。
#
#   bash release/build-release.sh                  # 默认 tag 1.16.2
#   bash release/build-release.sh --tag 1.16.3     # 换 tag（要求本地已有该镜像）
#   bash release/build-release.sh --skip-client    # 只出镜像 + compose 文件
#
# 产物在 release/dist/，服务器侧只需要这个目录：
#   planet-node-<tag>.tar.gz   离线备选：docker save 出来的镜像（服务器主路径是 docker pull，出不了外网才 docker load）
#   docker-compose.yml         与 compose/docker-compose.yml 逐字节相同
#   .env.example               install.sh 复制成 .env 的模板
#   Caddyfile                  tls profile 用
#   install.sh                 服务器侧安装脚本（不依赖任何源码）
#   README-部署.md             服务器侧唯一要看的文档
#   client/                    APK + 三平台安装脚本 + 客户端配置说明
#   SHA256SUMS                 以上所有文件的校验和（sha256sum -c 可直接验）
#
# 前置条件：开发机已经有镜像 ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>（先跑过 planet-node/build.sh）。
# 本脚本只打包、不编译任何东西。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

IMAGE_REPO='ccr.ccs.tencentyun.com/vnimy/zerotier-planet'
TAG="${PLANET_NODE_TAG:-1.16.2}"
GZIP_LEVEL="${GZIP_LEVEL:-6}"
WITH_CLIENT=1

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_OFF=$'\033[0m'
else
	C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_OFF=''
fi
log()  { printf '%s[build]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
	cat <<'USAGE'
用法: build-release.sh [选项]

选项:
  --tag <tag>      planet-node 镜像 tag，默认 1.16.2（也可用环境变量 PLANET_NODE_TAG）
  --skip-client    只出镜像 + compose 文件，不打包客户端
  --gzip <1-9>     镜像压缩级别，默认 6
  -h, --help       显示本帮助

产物: release/dist/ —— 整个目录拷到服务器就能装，不需要源码。
USAGE
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--tag)         [ "$#" -ge 2 ] && [ -n "$2" ] || die "--tag 需要一个值"; TAG="$2"; shift 2 ;;
		--gzip)        [ "$#" -ge 2 ] && [ -n "$2" ] || die "--gzip 需要一个值"; GZIP_LEVEL="$2"; shift 2 ;;
		--skip-client) WITH_CLIENT=0; shift ;;
		-h|--help)     usage; exit 0 ;;
		*)             usage >&2; die "未知参数: $1" ;;
	esac
done

case "$GZIP_LEVEL" in
	[1-9]) : ;;
	*) die "--gzip 只接受 1-9（当前 '$GZIP_LEVEL'）" ;;
esac

IMAGE="$IMAGE_REPO:$TAG"
TAR_NAME="planet-node-$TAG.tar.gz"

# ------------------------------------------------------------------ 环境预检
command -v docker >/dev/null 2>&1 || die "找不到 docker"
docker info >/dev/null 2>&1 || die "连不上 docker daemon（当前用户在 docker 组吗？）"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	die "缺少镜像 $IMAGE。本脚本只打包、不编译，先构建：
	cd $STACK_DIR/planet-node && ./build.sh      # 需要 ../ZeroTierOne 的 git 检出
	构建后镜像 tag 若不是 1.16.2，用 --tag <tag> 重跑本脚本（docker images $IMAGE_REPO 看实际 tag）"
fi

if [ ! -f "$STACK_DIR/compose/docker-compose.yml" ] || [ ! -f "$STACK_DIR/compose/.env.example" ] \
	|| [ ! -f "$STACK_DIR/compose/Caddyfile" ]; then
	die "缺少 compose/ 下的 docker-compose.yml、.env.example 或 Caddyfile（本脚本要在 zt-stack 仓库里跑）"
fi
[ -f "$SCRIPT_DIR/install.sh" ]     || die "缺少 release/install.sh"
[ -f "$SCRIPT_DIR/README-部署.md" ] || die "缺少 release/README-部署.md"

if [ "$WITH_CLIENT" -eq 1 ]; then
	APK="$STACK_DIR/artifacts/ZerotierFix-stage1-debug.apk"
	CLIENT_DOC="$SCRIPT_DIR/client/README-客户端.md"
	[ -f "$APK" ]        || die "缺少 $APK（客户端 APK；先构建，或加 --skip-client 只出服务端）"
	[ -f "$CLIENT_DOC" ] || die "缺少 $CLIENT_DOC"
	for f in clients/windows/install-planet.ps1 clients/windows/install-planet.cmd \
	         clients/linux/install-planet.sh clients/macos/install-planet.command; do
		[ -f "$STACK_DIR/$f" ] || die "缺少 $f"
	done
fi

# ------------------------------------------------------------------ 组装 dist
# 先在临时目录里拼好，成功后才替换 dist/：中途失败不会毁掉上一次的发布包。
TMP_DIR="$(mktemp -d "$SCRIPT_DIR/.dist.tmp.XXXXXX")"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

log "镜像 $IMAGE ($(docker image inspect --format '{{.Id}}' "$IMAGE" | cut -c1-19))"
mkdir -p "$TMP_DIR"

log "docker save -> $TAR_NAME"
if ! docker save "$IMAGE" | gzip "-$GZIP_LEVEL" >"$TMP_DIR/$TAR_NAME.part"; then
	die "docker save 失败（磁盘空间？镜像损坏？）"
fi
mv "$TMP_DIR/$TAR_NAME.part" "$TMP_DIR/$TAR_NAME"
ok "镜像已导出"

log "拷贝 compose 文件与安装脚本"
install -m 0644 "$STACK_DIR/compose/docker-compose.yml" "$TMP_DIR/docker-compose.yml"
install -m 0644 "$STACK_DIR/compose/.env.example"       "$TMP_DIR/.env.example"
install -m 0644 "$STACK_DIR/compose/Caddyfile"          "$TMP_DIR/Caddyfile"
install -m 0755 "$SCRIPT_DIR/install.sh"                "$TMP_DIR/install.sh"
install -m 0644 "$SCRIPT_DIR/README-部署.md"            "$TMP_DIR/README-部署.md"
ok "compose 文件与 install.sh 已打包"

if [ "$WITH_CLIENT" -eq 1 ]; then
	log "拷贝客户端"
	mkdir -p "$TMP_DIR/client/windows" "$TMP_DIR/client/linux" "$TMP_DIR/client/macos"
	install -m 0644 "$APK" "$TMP_DIR/client/ZerotierFix-stage1-debug.apk"
	install -m 0644 "$CLIENT_DOC" "$TMP_DIR/client/README-客户端.md"
	install -m 0644 "$STACK_DIR/clients/windows/install-planet.ps1" "$TMP_DIR/client/windows/install-planet.ps1"
	install -m 0644 "$STACK_DIR/clients/windows/install-planet.cmd" "$TMP_DIR/client/windows/install-planet.cmd"
	install -m 0755 "$STACK_DIR/clients/linux/install-planet.sh"    "$TMP_DIR/client/linux/install-planet.sh"
	install -m 0755 "$STACK_DIR/clients/macos/install-planet.command" "$TMP_DIR/client/macos/install-planet.command"
	ok "客户端已打包（APK + windows/linux/macos）"
else
	warn "按 --skip-client 跳过客户端"
fi

log "生成 SHA256SUMS"
( cd "$TMP_DIR" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum ) >"$TMP_DIR/SHA256SUMS"
ok "SHA256SUMS 覆盖 $(wc -l <"$TMP_DIR/SHA256SUMS") 个文件"

rm -rf "$DIST_DIR"
mv "$TMP_DIR" "$DIST_DIR"
trap - EXIT

# ------------------------------------------------------------------ 报告
TAR_PATH="$DIST_DIR/$TAR_NAME"
TAR_SIZE="$(stat -c '%s' "$TAR_PATH")"
TAR_SHA="$(sha256sum "$TAR_PATH" | cut -d' ' -f1)"
IMAGE_SIZE="$(docker images --format '{{.Size}}' "$IMAGE" | head -1)"; IMAGE_SIZE="${IMAGE_SIZE:-?}"

printf '\n'
ok "发布包已生成: $DIST_DIR"
printf '  镜像 tar      : %s\n' "$TAR_NAME"
printf '  压缩后大小    : %s (%s 字节)\n' "$(du -h "$TAR_PATH" | cut -f1)" "$TAR_SIZE"
printf '  镜像大小      : %s（未压缩；层已经压缩过，所以 tar.gz 只比它小一点）\n' "$IMAGE_SIZE"
printf '  tar sha256    : %s\n' "$TAR_SHA"
printf '  dist 总大小   : %s\n' "$(du -sh "$DIST_DIR" | cut -f1)"
printf '  dist 文件数   : %s\n' "$(find "$DIST_DIR" -type f | wc -l)"

printf '\n  dist/ 清单:\n'
( cd "$DIST_DIR" && find . -type f | sort | while IFS= read -r f; do
	printf '    %-42s %8s\n' "${f#./}" "$(du -h "$f" | cut -f1)"
done )

printf '\n  下一步:\n'
printf '    1) 把整个 dist/ 目录拷到服务器（scp -r / rsync -a 都行）\n'
printf '    2) 服务器上: cd dist && docker login ccr.ccs.tencentyun.com   # 私有仓库，首次必做\n'
printf '    3) 然后:     sha256sum -c SHA256SUMS && ./install.sh -i <公网IPv4>\n'
printf '    4) 详见 dist/README-部署.md（出不了外网时用目录里的 tar 离线装）\n'
