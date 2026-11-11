#!/usr/bin/env bash
# zerotier-planet 服务器侧安装脚本：只要 Docker + 这个目录，不装源码、不编译。
#
#   docker login ccr.ccs.tencentyun.com           # 默认镜像是私有仓库，服务器先登录
#   ./install.sh -i 203.0.113.10                  # 主路径：从 ccr 拉镜像起栈
#   ./install.sh -i 203.0.113.10                  # 离线：目录里有 planet-node-*.tar.gz 时自动 docker load
#   ./install.sh -i 203.0.113.10 --image my-registry.example.com/zt/planet-node:1.16.2
#                                                 # 覆盖默认镜像引用（先 pull 再打本地 tag）
#   ./install.sh -i 203.0.113.10 --tls-domain zt.example.com
#   ./install.sh --upgrade                        # 只重建 zerotier 容器（数据与面板不动）
#
# 幂等：已有的 .env 会被复用，口令、数据卷、identity 都不会被覆盖；命令行显式给出的项才更新。
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
ENV_EXAMPLE="$SCRIPT_DIR/.env.example"

IMAGE_REPO='ccr.ccs.tencentyun.com/vnimy/zerotier-planet'
DEFAULT_TAG='1.16.2'
TAG="$DEFAULT_TAG"
WAIT_SECONDS=300

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_OFF=$'\033[0m'
else
	C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_OFF=''
fi
log()  { printf '%s[zerotier-planet]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

usage() {
	cat <<'USAGE'
用法: install.sh -i <公网IPv4> [选项]

必填（首次安装）:
  -i, --ip <IPv4>         服务器公网 IPv4，会写进 planet 的 stableEndpoints

选项:
  -6, --ipv6 <IPv6>       额外通告的公网 IPv6（可选）
      --image <镜像引用>  覆盖默认镜像（默认 ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>）；
                          给了就先 docker pull 它，再打成本地 tag 供 compose 使用
      --tls-domain <域名> 启用 Caddy + HTTPS（域名需已解析到本机，放行 80/443）
      --upgrade           只重建 zerotier 容器（换镜像/换 tag 用；postgres/ztnet 不动）
      --wait <秒>         等 healthy 的超时，默认 300
      --no-wait           不等待健康检查
  -h, --help              显示本帮助

默认镜像是私有仓库的 ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>：
  首次安装前先在本机登录，否则拉取会被 401 拒绝（脚本会明确提示这条）：
      docker login ccr.ccs.tencentyun.com
  服务器不能出外网时改离线：把 dist 里的 planet-node-<tag>.tar.gz 放同目录，会自动 docker load。

示例:
  ./install.sh -i 203.0.113.10
  ./install.sh -i 203.0.113.10 --tls-domain zt.example.com
  ./install.sh -i 203.0.113.10 --image registry.example.com/zt/planet-node:1.16.2
  ./install.sh --upgrade
USAGE
}

ARG_IP=''; ARG_IPV6=''; IMAGE_REF=''; ARG_TLS_DOMAIN=''
UPGRADE=0; DO_WAIT=1; UPGRADE_ONLY=0

need_val() { { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "$1 需要一个值"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		-i|--ip)        need_val "$@"; ARG_IP="$2"; shift 2 ;;
		-6|--ipv6)      need_val "$@"; ARG_IPV6="$2"; shift 2 ;;
		--image)        need_val "$@"; IMAGE_REF="$2"; shift 2 ;;
		--tls-domain)   need_val "$@"; ARG_TLS_DOMAIN="$2"; shift 2 ;;
		--upgrade)      UPGRADE=1; shift ;;
		--wait)         need_val "$@"; WAIT_SECONDS="$2"; shift 2 ;;
		--no-wait)      DO_WAIT=0; shift ;;
		-h|--help)      usage; exit 0 ;;
		*)              usage >&2; die "未知参数: $1" ;;
	esac
done

# ------------------------------------------------------------------ 基础环境
command -v docker >/dev/null 2>&1 || die "找不到 docker：先安装 Docker Engine（或 Docker Desktop）"
docker info >/dev/null 2>&1 || die "连不上 docker daemon（当前用户在 docker 组里吗？试试 sudo 或 newgrp docker）"
docker compose version >/dev/null 2>&1 || die "缺少 docker compose v2 插件（docker compose version 应当有输出）"
[ -f "$COMPOSE_FILE" ] || die "缺少 $COMPOSE_FILE：发布包不完整，把整个 dist/ 重新拷一次"

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

env_get() {
	local key="$1"
	[ -f "$ENV_FILE" ] || return 0
	K="$key" awk 'BEGIN{k=ENVIRON["K"]} index($0,k"=")==1 {v=substr($0,length(k)+2)} END{if(v!="")print v}' "$ENV_FILE"
}

env_set() {
	local key="$1" val="$2" tmp="$ENV_FILE.tmp.$$"
	if grep -qE "^$key=" "$ENV_FILE" 2>/dev/null; then
		K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"];v=ENVIRON["V"]} index($0,k"=")==1 {print k"="v; next} {print}' "$ENV_FILE" >"$tmp"
		mv "$tmp" "$ENV_FILE"
	else
		printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
	fi
	chmod 600 "$ENV_FILE" 2>/dev/null || true
}

rand_hex() {
	local n="${1:-32}"
	if command -v openssl >/dev/null 2>&1; then openssl rand -hex "$n"
	else od -An -tx1 -N "$n" /dev/urandom | tr -d ' \n'; fi
}

is_ipv4() {
	local ip="$1" o
	[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	for o in "${BASH_REMATCH[@]:1}"; do [ "$((10#$o))" -le 255 ] || return 1; done
	return 0
}

is_ipv6() {
	[[ "$1" == *:* ]] || return 1
	[[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
	return 0
}

container_health() {
	docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo absent
}

wait_healthy() {
	local name="$1" timeout="${2:-300}" waited=0 status
	while [ "$waited" -lt "$timeout" ]; do
		status="$(container_health "$name")"
		case "$status" in
			healthy)   return 0 ;;
			unhealthy) warn "$name unhealthy，用 docker logs $name 看原因"; return 1 ;;
			absent)    return 1 ;;
		esac
		sleep 3; waited=$((waited + 3))
	done
	warn "$name 在 ${timeout}s 内没有变成 healthy（当前 $status）"
	return 1
}

ref_tag() {
	local ref="$1" last
	case "$ref" in *@*) return 0 ;; esac
	last="${ref##*/}"
	case "$last" in *:*) printf '%s' "${last##*:}" ;; *) return 0 ;; esac
}

# ------------------------------------------------------------------ 镜像
# 默认镜像是私有仓库的 $IMAGE_REPO:<tag>：服务器主路径是 docker pull；
# dist 里带了 planet-node-<tag>.tar.gz 时，registry 不可用会退回 docker load（离线备选）。
REGISTRY_HOST="${IMAGE_REPO%%/*}"
TAR_FILE="$(ls -1 "$SCRIPT_DIR"/planet-node-*.tar.gz 2>/dev/null | sort | head -1 || true)"
if [ -n "$TAR_FILE" ]; then
	tar_tag="$(basename "$TAR_FILE")"
	tar_tag="${tar_tag#planet-node-}"
	tar_tag="${tar_tag%.tar.gz}"
	[ -n "$tar_tag" ] && TAG="$tar_tag"
fi
if [ -n "$IMAGE_REF" ]; then
	ref_tag_val="$(ref_tag "$IMAGE_REF")"
	[ -n "$ref_tag_val" ] && TAG="$ref_tag_val"
fi
IMAGE="$IMAGE_REPO:$TAG"

# 私有仓库登录提示：config.json 里查不到凭据只"提醒"、不拦人（用 credential store 时 auths 是空的，
# 所以这里不下结论，最终以 docker pull 的结果为准）。
docker_has_login() {
	local cfg
	if [ -n "${DOCKER_CONFIG:-}" ]; then cfg="$DOCKER_CONFIG/config.json"
	else cfg="${HOME:-/root}/.docker/config.json"; fi
	[ -f "$cfg" ] || return 1
	grep -q "\"$1" "$cfg" 2>/dev/null
}

login_hint() {
	cat >&2 <<EOF
	默认镜像是私有仓库：$IMAGE_REPO
	私有仓库要先登录；登录 token 也可能过期/时序失败（oauth token … unexpected EOF 就是这种）。
	两种情况是同一条命令（用户名/密码用你们自己的）：
	    docker login $REGISTRY_HOST
	登录后重跑：./install.sh -i <公网IP>
	服务器出不了外网就改离线：把 planet-node-$TAG.tar.gz 放到 $SCRIPT_DIR，重跑同一条命令。
EOF
}

is_auth_error() {
	case "$1" in
		*401*|*Unauthorized*|*unauthorized*|*"authentication required"*|*"oauth token"*|*"no basic auth"*|*"access forbidden"*|*"insufficient_scope"*|*"denied: requested access"*) return 0 ;;
	esac
	return 1
}

# pull_ref REF -> 成功返回 0；失败把 registry 原始输出留给人看，再按鉴权/其它两类给提示
pull_ref() {
	local ref="$1" out
	log "从 registry 拉取: $ref"
	if out="$(docker pull "$ref" 2>&1)"; then
		printf '%s\n' "$out" | tail -2
		return 0
	fi
	printf '%s\n' "$out" >&2
	if is_auth_error "$out"; then
		warn "仓库拒绝了这个请求（401/鉴权失败），不是网络问题："
		login_hint
	else
		warn "拉取失败：网络不通或镜像 tag 不存在。"
	fi
	return 1
}

# load_tar -> 从 dist 里的 tar 恢复镜像（离线备选路径）
load_tar() {
	local tar_sha
	tar_sha="$(sha256sum "$TAR_FILE" | cut -d' ' -f1)"
	log "docker load $(basename "$TAR_FILE")（$(du -h "$TAR_FILE" | cut -f1)，sha256 $tar_sha）"
	docker load -i "$TAR_FILE" >/dev/null || die "docker load 失败: $TAR_FILE（文件损坏？重拷一次 dist/）"
	docker image inspect "$IMAGE" >/dev/null 2>&1 || die "tar 已载入，但没有 $IMAGE
	tar 内的 tag 与文件名不一致：docker images $IMAGE_REPO 看实际 tag，
	把 tar 改名为 planet-node-<tag>.tar.gz 后重跑"
	ok "已载入镜像 $IMAGE（离线 tar）"
}

if [ -n "$IMAGE_REF" ]; then
	# 显式给了镜像引用：拉它，再打成本地 tag（compose 里引用的仍是默认名）
	pull_ref "$IMAGE_REF" || die "拿不到 $IMAGE_REF（原因见上）"
	docker tag "$IMAGE_REF" "$IMAGE" || die "docker tag 失败: $IMAGE_REF -> $IMAGE"
	ok "已就绪: $IMAGE（来自 $IMAGE_REF）"
elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
	ok "本地已有镜像 $IMAGE（跳过拉取与 docker load）"
else
	if ! docker_has_login "$REGISTRY_HOST"; then
		warn "本机没找到 $REGISTRY_HOST 的登录凭据（默认镜像是私有仓库，通常要先 docker login）"
	fi
	if pull_ref "$IMAGE"; then
		ok "已拉取 $IMAGE"
	elif [ -n "$TAR_FILE" ]; then
		warn "registry 不可用，退回离线 tar"
		load_tar
	else
		die "拿不到镜像 $IMAGE：registry 拉取失败，且本目录没有 planet-node-*.tar.gz
	服务器能上网时的正常做法：
	     docker login $REGISTRY_HOST
	     ./install.sh -i <公网IP>
	服务器不能上网时（离线）：
	     把 planet-node-$TAG.tar.gz 放到 $SCRIPT_DIR，重跑同一条命令"
	fi
fi
# ------------------------------------------------------------------ .env
if [ ! -f "$ENV_FILE" ]; then
	[ -f "$ENV_EXAMPLE" ] || die "缺少 $ENV_EXAMPLE：发布包不完整，把整个 dist/ 重新拷一次"
	cp "$ENV_EXAMPLE" "$ENV_FILE"
	chmod 600 "$ENV_FILE" 2>/dev/null || true
	ok "已从 .env.example 生成 .env"
else
	log "复用已有 .env（已有口令与端口不被覆盖）"
fi

if [ -z "$(env_get NEXTAUTH_SECRET)" ]; then env_set NEXTAUTH_SECRET "$(rand_hex 32)"; ok "生成 NEXTAUTH_SECRET"; fi
if [ -z "$(env_get POSTGRES_PASSWORD)" ]; then env_set POSTGRES_PASSWORD "$(rand_hex 24)"; ok "生成 POSTGRES_PASSWORD"; fi
if [ -z "$(env_get DOWNLOAD_TOKEN)" ]; then env_set DOWNLOAD_TOKEN "$(rand_hex 16)"; ok "生成 DOWNLOAD_TOKEN（planet 下载需要凭据）"; fi

# ------------------------------------------------------------------ 公网地址
PREV_IP="$(env_get PUBLIC_IPV4)"
PREV_TLS_DOMAIN="$(env_get TLS_DOMAIN)"
PREV_ZTNET_PORT="$(env_get ZTNET_PORT)"; PREV_ZTNET_PORT="${PREV_ZTNET_PORT:-3001}"
CUR_URL="$(env_get NEXTAUTH_URL)"

IP="${ARG_IP:-}"
[ -n "$IP" ] || IP="$PREV_IP"
[ -n "$IP" ] || die "缺少服务器公网 IPv4：用 -i/--ip <IPv4> 指定（不猜 IP）"
is_ipv4 "$IP" || die "--ip '$IP' 不是合法 IPv4"
if [ "$IP" = '127.0.0.1' ] || [ "$IP" = '0.0.0.0' ]; then
	die "--ip $IP 不能作为 planet 端点：客户端要从公网连到它，填服务器真实公网 IPv4"
fi
case "$IP" in
	10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
		warn "PUBLIC_IPV4=$IP 是内网地址：只有能路由到它的客户端可用（本机/内网测试可以，公网要填公网 IP）" ;;
esac

IPV6="${ARG_IPV6:-$(env_get PUBLIC_IPV6)}"
if [ -n "$IPV6" ]; then is_ipv6 "$IPV6" || die "--ipv6 '$IPV6' 不是合法 IPv6"; fi

ZT_PORT="$(env_get ZT_PORT)";       ZT_PORT="${ZT_PORT:-9994}"
FILES_PORT="$(env_get FILES_PORT)"; FILES_PORT="${FILES_PORT:-3000}"
ZTNET_PORT="$(env_get ZTNET_PORT)"; ZTNET_PORT="${ZTNET_PORT:-3001}"

TLS_DOMAIN="${ARG_TLS_DOMAIN:-$PREV_TLS_DOMAIN}"

env_set PLANET_NODE_TAG "$TAG"
env_set PUBLIC_IPV4 "$IP"
env_set PUBLIC_IPV6 "$IPV6"
env_set ZT_PORT "$ZT_PORT"
env_set FILES_PORT "$FILES_PORT"
env_set ZTNET_PORT "$ZTNET_PORT"
if [ -n "$TLS_DOMAIN" ]; then env_set TLS_DOMAIN "$TLS_DOMAIN"; fi

# NEXTAUTH_URL 必须等于浏览器真实访问的地址，否则 ZTNet 登录会被 Origin 校验拒成 403。
if [ -n "$TLS_DOMAIN" ]; then DESIRED_URL="https://$TLS_DOMAIN"
else DESIRED_URL="http://$IP:$ZTNET_PORT"; fi
KEEP_URL=0
if [ -n "$CUR_URL" ] && [ "$CUR_URL" != "$DESIRED_URL" ]; then
	KEEP_URL=1
	[ "$CUR_URL" = "http://$PREV_IP:$PREV_ZTNET_PORT" ] && KEEP_URL=0
	[ -n "$PREV_TLS_DOMAIN" ] && [ "$CUR_URL" = "https://$PREV_TLS_DOMAIN" ] && KEEP_URL=0
fi
if [ "$KEEP_URL" -eq 1 ]; then
	warn "保留已有的 NEXTAUTH_URL=$CUR_URL（手改过就不覆盖；想让面板跟随 IP/域名，删掉这一行后重跑）"
else
	env_set NEXTAUTH_URL "$DESIRED_URL"
fi

PROFILE_ARGS=()
if [ -n "$TLS_DOMAIN" ]; then
	PROFILE_ARGS=(--profile tls)
	log "启用 TLS：域名 $TLS_DOMAIN（需放行 80/443，且域名已解析到本机）"
fi
run_compose() { if [ "${#PROFILE_ARGS[@]}" -gt 0 ]; then compose "${PROFILE_ARGS[@]}" "$@"; else compose "$@"; fi; }

log "校验 compose 配置"
if ! run_compose config -q 2>"$ENV_FILE.config.err"; then
	cat "$ENV_FILE.config.err" >&2; rm -f "$ENV_FILE.config.err"
	die "docker compose config 校验失败（多半是 .env 里缺值）"
fi
rm -f "$ENV_FILE.config.err"
ok "compose 配置有效"

REGEN=0
if [ -n "$PREV_IP" ] && [ "$PREV_IP" != "$IP" ]; then
	REGEN=1
	env_set REGENERATE_WORLD 1
	warn "PUBLIC_IPV4 从 $PREV_IP 变成 $IP：本次只重建 planet（identity 与网络 ID 不变，但所有成员要重新下载 planet）"
else
	env_set REGENERATE_WORLD 0
fi

# ------------------------------------------------------------------ 起栈
HEALTH_FAIL=0
if [ "$UPGRADE" -eq 1 ]; then
	if docker inspect zerotier-planet-zerotier >/dev/null 2>&1; then
		log "--upgrade：只重建 zerotier 容器（postgres/ztnet 与数据卷不动）"
		run_compose up -d --no-deps --force-recreate zerotier || die "重建 zerotier 容器失败，见上面的输出"
		if [ "$DO_WAIT" -eq 1 ]; then
			if wait_healthy zerotier-planet-zerotier "$WAIT_SECONDS"; then ok "zerotier-planet-zerotier healthy"; else HEALTH_FAIL=1; fi
		fi
		env_set REGENERATE_WORLD 0
		UPGRADE_ONLY=1
	else
		warn "栈还没装过（找不到 zerotier-planet-zerotier 容器），--upgrade 按首次安装处理"
		UPGRADE=0
	fi
fi

if [ "$UPGRADE_ONLY" -eq 0 ]; then
	log "docker compose up -d"
	if ! run_compose up -d --pull missing; then
		die "启动失败。若是面板/数据库镜像拉不下来（输出里有 pull access denied / TLS handshake timeout），
	在 .env 里把 ZTNET_IMAGE / POSTGRES_IMAGE 换成服务器能访问的镜像源后重跑本脚本。"
	fi
	ok "容器已启动"
	if [ "$REGEN" -eq 1 ]; then
		log "强制重建 zerotier 让新端点生效"
		run_compose up -d --no-deps --force-recreate zerotier || warn "强制重建 zerotier 失败，手动执行: docker compose up -d --no-deps --force-recreate zerotier"
	fi
	if [ "$DO_WAIT" -eq 1 ]; then
		for svc in zerotier-planet-postgres zerotier-planet-zerotier zerotier-planet-ztnet; do
			log "等待 $svc healthy（最多 ${WAIT_SECONDS}s）"
			if wait_healthy "$svc" "$WAIT_SECONDS"; then ok "$svc healthy"; else HEALTH_FAIL=1; fi
		done
	else
		warn "--no-wait：跳过健康等待"
	fi
	if [ "$REGEN" -eq 1 ] && [ "$HEALTH_FAIL" -eq 0 ]; then
		env_set REGENERATE_WORLD 0
		ok "planet 已按新端点重建（REGENERATE_WORLD 复位为 0）"
	fi
fi

# ------------------------------------------------------------------ 汇报
PUBLIC_IPV4="$(env_get PUBLIC_IPV4)"; PUBLIC_IPV6="$(env_get PUBLIC_IPV6)"
ZT_PORT="$(env_get ZT_PORT)"; FILES_PORT="$(env_get FILES_PORT)"
ZTNET_PORT="$(env_get ZTNET_PORT)"; DOWNLOAD_TOKEN="$(env_get DOWNLOAD_TOKEN)"
TLS_DOMAIN="$(env_get TLS_DOMAIN)"; PANEL_URL="$(env_get NEXTAUTH_URL)"
PLANET_QS=""; [ -n "$DOWNLOAD_TOKEN" ] && PLANET_QS="?token=$DOWNLOAD_TOKEN"
PLANET_URL="http://$PUBLIC_IPV4:$FILES_PORT/planet"

echo
echo "================ zerotier-planet 安装结果 ================"
printf '  公网端点        : %s:%s (tcp+udp)\n' "$PUBLIC_IPV4" "$ZT_PORT"
[ -n "$PUBLIC_IPV6" ] && printf '  IPv6 端点       : [%s]:%s\n' "$PUBLIC_IPV6" "$ZT_PORT"
printf '  镜像            : %s\n' "$IMAGE"
printf '  ZTNet 面板      : %s\n' "$PANEL_URL"
[ -n "$TLS_DOMAIN" ] && printf '  TLS 域名        : https://%s/   (planet: https://%s/planet)\n' "$TLS_DOMAIN" "$TLS_DOMAIN"
printf '  planet 下载     : %s%s\n' "$PLANET_URL" "$PLANET_QS"
printf '  健康检查        : http://%s:%s/healthz\n' "$PUBLIC_IPV4" "$FILES_PORT"
if [ -n "$DOWNLOAD_TOKEN" ]; then
	printf '  下载凭据        : ?token=%s 或 Authorization: Bearer（Android 只发 Bearer 头）\n' "$DOWNLOAD_TOKEN"
else
	printf '  下载凭据        : 未启用（任何人可下载 planet）\n'
fi
echo "  防火墙必须放行  :"
printf '                    %s/tcp %s/udp   ZeroTier peer + API/controller\n' "$ZT_PORT" "$ZT_PORT"
printf '                    %s/tcp          planet/moon 下载\n' "$FILES_PORT"
printf '                    %s/tcp          ZTNet 面板\n' "$ZTNET_PORT"
[ -n "$TLS_DOMAIN" ] && printf '                    80/tcp 443/tcp 443/udp   Caddy ACME + HTTPS\n'
echo "  下一步          :"
echo "                    1) 浏览器打开面板，注册第一个管理员账号（第一个注册的账号是管理员）"
echo "                    2) 客户端：Android 装 client/ZeroTier-1.16.2-debug.apk，"
printf '                       设置 -> 行星服务器（自动下载）-> 填 %s（token 可选）\n' "$PLANET_URL"
echo "                    3) 桌面端：client/windows|linux|macos 里的脚本，用法见 client/README-客户端.md"
echo "                    4) 备份与换 IP：见 README-部署.md"
echo "==================================================="

if [ "$HEALTH_FAIL" -eq 1 ]; then
	warn "有服务没到 healthy：docker compose ps 与 docker logs <容器名> 排查（镜像/端口/数据库口令）"
	exit 1
fi
ok "安装完成"
