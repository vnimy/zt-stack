#!/usr/bin/env bash
# 一条命令部署 ZeroTier 行星节点 + ZTNet + PostgreSQL。
#
#   ./deploy.sh -i 203.0.113.10                           # 首次部署
#   ./deploy.sh -i 203.0.113.10 --tls -d zt.example.com    # 加 Caddy + 域名 TLS
#   ./deploy.sh --upgrade                                  # 拉新镜像原地重建，保留身份与数据
#   ./deploy.sh -i <新IP>                                  # 换 IP：只重建 planet，identity/网络 ID 不变
#
# 幂等：已有 .env 时保留其中的口令与 planet 数据，只更新命令行显式给出的项。
# 所有参数都能用同名环境变量代替：PUBLIC_IPV4 / PUBLIC_IPV6 / ZT_PORT / FILES_PORT /
# ZTNET_PORT / DOWNLOAD_TOKEN / TLS_DOMAIN。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

usage() {
	cat <<'USAGE'
用法: deploy.sh -i <公网IPv4> [选项]

必填（首次部署）:
  -i, --ip <IPv4>          服务器公网 IPv4，会被写进 planet 的 stableEndpoints

常用选项:
  -6, --ipv6 <IPv6>        额外通告的公网 IPv6
      --zt-port <端口>     公网 peer/API 端口，默认 9994（容器内始终 9993）
      --files-port <端口>  planet 下载服务端口，默认 3000
      --ztnet-port <端口>  ZTNet 面板端口，默认 3001（3000 留给 planet 下载）
      --download-token [值] 启用 planet 下载鉴权（不给值则随机生成；默认就启用）
      --no-download-token  关闭下载鉴权（任何人可下 planet）
      --nextauth-url <URL> 面板对外地址，默认 http://<IP>:<ztnet-port>
  -d, --domain <域名>      启用 TLS profile，用 Caddy 反代（域名需已解析到本机）
      --upgrade            先 docker compose pull 再原地重建（保留身份/数据）
      --force-new-identity 全量重建：换新 identity -> 所有自建网络 ID 失效，成员要重新 join
      --force-regenerate   同 --force-new-identity（旧名，保留兼容）
      --wait <秒>          等待 healthy 的超时，默认 300
      --no-wait            不等待健康检查，起完就返回
  -h, --help               显示本帮助

示例:
  ./deploy.sh -i 203.0.113.10
  ./deploy.sh -i 203.0.113.10 --ztnet-port 8080 --no-download-token
  ./deploy.sh -i 203.0.113.10 --tls -d zt.example.com
  ./deploy.sh -i <换了公网IP>        # 只重建 planet（REGENERATE_WORLD=1），identity/网络 ID 不变
  ./deploy.sh -i <IP> --force-new-identity   # 连 identity 一起换（所有网络 ID 失效）
  ./deploy.sh --upgrade
USAGE
}

ARG_IP=''; ARG_IPV6=''; ARG_ZT_PORT=''; ARG_FILES_PORT=''; ARG_ZTNET_PORT=''
ARG_DOMAIN=''; ARG_NEXTAUTH_URL=''; ARG_TOKEN=''; TOKEN_MODE='keep'
UPGRADE=0; FORCE_REGEN=0; WAIT_SECONDS=300; DO_WAIT=1

need_val() { { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "$1 需要一个值"; }

while [ "$#" -gt 0 ]; do
	case "$1" in
		-i|--ip)             need_val "$@"; ARG_IP="$2"; shift 2 ;;
		-6|--ipv6)           need_val "$@"; ARG_IPV6="$2"; shift 2 ;;
		--zt-port)           need_val "$@"; ARG_ZT_PORT="$2"; shift 2 ;;
		--files-port)        need_val "$@"; ARG_FILES_PORT="$2"; shift 2 ;;
		--ztnet-port)        need_val "$@"; ARG_ZTNET_PORT="$2"; shift 2 ;;
		-d|--domain)         need_val "$@"; ARG_DOMAIN="$2"; shift 2 ;;
		--nextauth-url)      need_val "$@"; ARG_NEXTAUTH_URL="$2"; shift 2 ;;
		--download-token)
			if [ "$#" -ge 2 ] && [ "${2:0:2}" != "--" ]; then ARG_TOKEN="$2"; shift 2
			else TOKEN_MODE='generate'; shift; fi ;;
		--no-download-token) TOKEN_MODE='disable'; shift ;;
		--upgrade)           UPGRADE=1; shift ;;
		--force-regenerate|--force-new-identity) FORCE_REGEN=1; shift ;;
		--wait)              need_val "$@"; WAIT_SECONDS="$2"; shift 2 ;;
		--no-wait)           DO_WAIT=0; shift ;;
		-h|--help)           usage; exit 0 ;;
		*)                   usage >&2; die "未知参数: $1" ;;
	esac
done

require_docker

# --------------------------------------------------------------- 镜像预检
# compose 里 zerotier 用的是 ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>（可用 PLANET_NODE_IMAGE 覆盖）。
# 镜像不存在时 compose 只会抛一句 pull 原始错误，这里提前拦住并给出精确的下一步
# （先 docker pull；没有仓库权限再本机构建 / 改用 release 分发包）。
PLANET_NODE_TAG_EFF="${PLANET_NODE_TAG:-$(env_get PLANET_NODE_TAG)}"
PLANET_NODE_TAG_EFF="${PLANET_NODE_TAG_EFF:-1.16.2}"
PLANET_NODE_IMAGE="${PLANET_NODE_IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-planet:${PLANET_NODE_TAG_EFF}}"
if docker image inspect "$PLANET_NODE_IMAGE" >/dev/null 2>&1; then
	ok "planet-node 镜像已就绪: $PLANET_NODE_IMAGE"
elif [ -x "$STACK_DIR/planet-node/build.sh" ]; then
	die "缺少镜像 $PLANET_NODE_IMAGE（compose 的 zerotier 用它）。三选一：
	1) 直接从镜像仓库拉取（默认仓库 ccr.ccs.tencentyun.com/vnimy/zerotier-planet）：
	     docker pull $PLANET_NODE_IMAGE
	2) 本机源码构建（需要 ../ZeroTierOne 的 git 检出）：
	     cd $STACK_DIR/planet-node && ./build.sh
	3) 镜像优先（服务器不装源码、不编译）：
	     开发机: bash $STACK_DIR/release/build-release.sh
	     把 release/dist/ 拷到服务器，在服务器上: bash install.sh -i <公网IP>
	     详见 release/README-部署.md"
else
	die "缺少镜像 $PLANET_NODE_IMAGE，且本机没有 planet-node/build.sh（不是完整源码树）。
	这个部署形态需要源码 + 构建环境，本机没有。改用镜像优先形态：
	 开发机: bash release/build-release.sh   # 打出 release/dist/
	 服务器: 拷入 dist/ 后执行 ./install.sh -i <公网IP>
	 已有 registry 镜像则用: ./install.sh -i <公网IP> --image <registry>/<tag>"
fi

# --------------------------------------------------------------- .env 准备
if [ ! -f "$ENV_FILE" ]; then
	[ -f "$ENV_EXAMPLE" ] || die "缺少模板 $ENV_EXAMPLE"
	cp "$ENV_EXAMPLE" "$ENV_FILE"
	chmod 600 "$ENV_FILE"
	ok "已从 .env.example 生成 compose/.env（权限 600）"
else
	log "复用已有的 compose/.env（口令与端口不会被覆盖）"
fi

# 口令类：空则生成，非空则保留
if [ -z "$(env_get NEXTAUTH_SECRET)" ]; then
	env_set NEXTAUTH_SECRET "$(rand_hex 32)"
	ok "生成 NEXTAUTH_SECRET"
fi
if [ -z "$(env_get POSTGRES_PASSWORD)" ]; then
	env_set POSTGRES_PASSWORD "$(rand_hex 24)"
	ok "生成 POSTGRES_PASSWORD"
fi
# 默认策略：首次部署自动生成下载 token（README 承诺的行为），之后保留已有值
if [ "$TOKEN_MODE" = 'keep' ] && [ -z "$(env_get DOWNLOAD_TOKEN)" ]; then
	TOKEN_MODE='generate'
fi
case "$TOKEN_MODE" in
	generate) env_set DOWNLOAD_TOKEN "$(rand_hex 16)"; ok "生成 DOWNLOAD_TOKEN" ;;
	disable)  env_set DOWNLOAD_TOKEN ''; ok "已关闭 planet 下载鉴权（DOWNLOAD_TOKEN 为空）" ;;
	*)        : ;;
esac
if [ -n "$ARG_TOKEN" ]; then env_set DOWNLOAD_TOKEN "$ARG_TOKEN"; ok "使用命令行给出的 DOWNLOAD_TOKEN"; fi

# --------------------------------------------------------------- 公网 IP
PREV_IP="$(env_get PUBLIC_IPV4)"
IP="${ARG_IP:-${PUBLIC_IPV4:-}}"
[ -n "$IP" ] || IP="$PREV_IP"
[ -n "$IP" ] || die "缺少服务器公网 IPv4：用 -i/--ip <IPv4> 或环境变量 PUBLIC_IPV4 指定（不猜 IP）"
is_ipv4 "$IP" || die "PUBLIC_IPV4='$IP' 不是合法 IPv4"
if [ "$IP" = '0.0.0.0' ] || [ "$IP" = '127.0.0.1' ]; then
	die "PUBLIC_IPV4='$IP' 不能作为 planet 端点：客户端必须能从公网连到它"
fi
case "$IP" in
	10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*)
		warn "PUBLIC_IPV4=$IP 是内网地址：只有能路由到它的客户端才能用（本机测试可以，生产请填公网 IP）" ;;
esac

IPV6="${ARG_IPV6:-${PUBLIC_IPV6:-}}"
if [ -n "$IPV6" ]; then is_ipv6 "$IPV6" || die "PUBLIC_IPV6='$IPV6' 不是合法 IPv6"; fi

# 端口（先记下旧值：判断 NEXTAUTH_URL 是不是上一次自动生成的默认值）
PREV_ZTNET_PORT="$(env_get ZTNET_PORT)"
ZT_PORT_ARG="${ARG_ZT_PORT:-${ZT_PORT:-}}";       ZT_PORT_ARG="${ZT_PORT_ARG:-$(env_get ZT_PORT)}";      ZT_PORT_ARG="${ZT_PORT_ARG:-9994}"
FILES_PORT_ARG="${ARG_FILES_PORT:-${FILES_PORT:-}}"; FILES_PORT_ARG="${FILES_PORT_ARG:-$(env_get FILES_PORT)}"; FILES_PORT_ARG="${FILES_PORT_ARG:-3000}"
ZTNET_PORT_ARG="${ARG_ZTNET_PORT:-${ZTNET_PORT:-}}"; ZTNET_PORT_ARG="${ZTNET_PORT_ARG:-$(env_get ZTNET_PORT)}"; ZTNET_PORT_ARG="${ZTNET_PORT_ARG:-3001}"
for p in "$ZT_PORT_ARG" "$FILES_PORT_ARG" "$ZTNET_PORT_ARG"; do is_port "$p" || die "'$p' 不是合法端口（1-65535 的数字）"; done

env_set PUBLIC_IPV4 "$IP"
env_set PUBLIC_IPV6 "$IPV6"
env_set ZT_PORT "$ZT_PORT_ARG"
env_set FILES_PORT "$FILES_PORT_ARG"
env_set ZTNET_PORT "$ZTNET_PORT_ARG"
if [ -n "$ARG_DOMAIN" ]; then env_set TLS_DOMAIN "$ARG_DOMAIN"; fi
TLS_DOMAIN="$(env_get TLS_DOMAIN)"

# 面板对外地址
if [ -n "$ARG_NEXTAUTH_URL" ]; then
	env_set NEXTAUTH_URL "$ARG_NEXTAUTH_URL"
elif [ -n "$TLS_DOMAIN" ]; then
	env_set NEXTAUTH_URL "https://$TLS_DOMAIN"
else
	CUR_URL="$(env_get NEXTAUTH_URL)"
	case "$CUR_URL" in
		''|http://127.0.0.1:*|http://localhost:*|"http://$IP:$ZTNET_PORT_ARG"|"http://$PREV_IP:${PREV_ZTNET_PORT:-3001}")
			# 空值、本地占位地址、已经正确、或只是上一次自动生成的默认值（IP/端口变了要跟着改）
			env_set NEXTAUTH_URL "http://$IP:$ZTNET_PORT_ARG" ;;
	esac
fi

# --------------------------------------------------------------- planet 重建判定
# 两种重建互斥，语义见 docs/OPERATIONS.md「改 IP」：
#   REGENERATE_WORLD=1  只重写 planet/moons（新端点+新时间戳），identity/authtoken/controller
#                       数据/签名密钥都保留 -> network id、成员授权不变，但成员必须重新下载 planet
#   FORCE_REGENERATE=1  全量重建（新 identity）-> 所有自建网络 ID 失效，成员要重新 join
OPEN_REGEN_VAR=''
REGEN_KIND='none'
if [ "$FORCE_REGEN" -eq 1 ]; then
	REGEN_KIND='full'
	env_set FORCE_REGENERATE 1
	env_set REGENERATE_WORLD 0
	OPEN_REGEN_VAR='FORCE_REGENERATE'
	warn "全量重建（--force-new-identity）：identity 会重新生成，所有自建网络的 network id 全部失效，成员必须重新 join"
elif [ -n "$PREV_IP" ] && [ "$PREV_IP" != "$IP" ]; then
	REGEN_KIND='world'
	env_set REGENERATE_WORLD 1
	env_set FORCE_REGENERATE 0
	OPEN_REGEN_VAR='REGENERATE_WORLD'
	warn "PUBLIC_IPV4 从 $PREV_IP 变成 $IP：本次只重建 planet（REGENERATE_WORLD=1）"
	log  "  - identity 与网络 ID 保持不变，控制器数据、成员授权都还在"
	log  "  - 但 planet 里的端点变了：所有成员必须重新下载 planet（world id 不变，端点变）"
	log  "  - authtoken 不变，ZTNet 不需要重启"
else
	env_set FORCE_REGENERATE 0
	env_set REGENERATE_WORLD 0
fi

# --------------------------------------------------------------- 校验配置
log "校验 compose 配置"
CONFIG_ERR="$(mktemp)"
if ! compose config -q 2>"$CONFIG_ERR"; then
	cat "$CONFIG_ERR" >&2; rm -f "$CONFIG_ERR"
	die "docker compose config 校验失败（多半是 .env 没填全）"
fi
rm -f "$CONFIG_ERR"
ok "compose 配置有效"

PROFILE_ARGS=()
if [ -n "$TLS_DOMAIN" ]; then
	PROFILE_ARGS=(--profile tls)
	log "启用 TLS profile：域名 $TLS_DOMAIN（需 80/443 放行且域名已解析到本机）"
fi

# --------------------------------------------------------------- 起栈
if [ "$UPGRADE" -eq 1 ]; then
	log "--upgrade：先 pull 最新镜像（失败不致命，继续用本地镜像）"
	compose "${PROFILE_ARGS[@]}" pull || warn "docker compose pull 有失败项，继续使用本地镜像"
fi

UP_TRY=1
while :; do
	log "docker compose up -d（第 $UP_TRY 次尝试）"
	if compose "${PROFILE_ARGS[@]}" up -d --pull missing; then break; fi
	if [ "$UP_TRY" -ge 2 ]; then die "docker compose up 连续失败，见上面的输出"; fi
	UP_TRY=$((UP_TRY + 1)); warn "up 失败，5 秒后重试一次"; sleep 5
done
ok "容器已启动"

# 重建类请求必须让 zerotier 容器真的重建：只改 .env 里那个开关，遇到"容器里已经是 1、
# .env 又要写 1"的情况时 compose 判定配置未变、不会重建，重建请求就被吞掉了
# （连续两次同样的重建请求时最容易踩到）。所以这里显式 --force-recreate。
if [ "$REGEN_KIND" != 'none' ]; then
	log "按 $REGEN_KIND 重建 planet：强制重建 zerotier 容器"
	compose "${PROFILE_ARGS[@]}" up -d --no-deps --force-recreate zerotier || warn "强制重建 zerotier 失败"
fi

# --------------------------------------------------------------- 等健康
HEALTH_FAIL=0
if [ "$DO_WAIT" -eq 1 ]; then
	for svc in zerotier-planet-postgres zerotier-planet-zerotier zerotier-planet-ztnet; do
		log "等待 $svc healthy（最多 ${WAIT_SECONDS}s）"
		if wait_healthy "$svc" "$WAIT_SECONDS"; then ok "$svc healthy"; else HEALTH_FAIL=1; fi
	done
else
	warn "--no-wait：跳过健康等待"
fi

if [ -n "$OPEN_REGEN_VAR" ] && [ "$HEALTH_FAIL" -eq 0 ]; then
	env_set "$OPEN_REGEN_VAR" 0
	ok "planet 重建完成（$REGEN_KIND），$OPEN_REGEN_VAR 复位为 0"
fi

# identity 换了 -> authtoken 也换了。ZTNet 只在模块加载时读一次 authtoken，
# 不重启就会一直拿旧口令调控制器（面板里网络列表报错）。这里自动重启一次。
if [ "$REGEN_KIND" = 'full' ] && [ "$HEALTH_FAIL" -eq 0 ]; then
	log "identity 已更换：authtoken 随之变化，重启 ztnet 让它重读"
	compose restart ztnet >/dev/null 2>&1 || warn "docker compose restart ztnet 失败，请手动执行"
	if wait_healthy zerotier-planet-ztnet "$WAIT_SECONDS"; then ok "ztnet 已重读 authtoken 并 healthy"; else warn "ztnet 重启后没到 healthy"; HEALTH_FAIL=1; fi
fi

# --------------------------------------------------------------- 汇报
stack_summary_vars
PLANET_QS=""
[ -n "$DOWNLOAD_TOKEN" ] && PLANET_QS="?token=$DOWNLOAD_TOKEN"
PANEL_URL="$(env_get NEXTAUTH_URL)"

echo
echo "================ zerotier-planet 部署结果 ================"
printf '  公网端点        : %s:%s (tcp+udp)\n' "$PUBLIC_IPV4" "$ZT_PORT"
[ -n "$PUBLIC_IPV6" ] && printf '  IPv6 端点       : [%s]:%s\n' "$PUBLIC_IPV6" "$ZT_PORT"
printf '  ZTNet 面板      : %s\n' "$PANEL_URL"
[ -n "$TLS_DOMAIN" ] && printf '  TLS 域名        : https://%s/   (planet: https://%s/planet)\n' "$TLS_DOMAIN" "$TLS_DOMAIN"
printf '  planet 下载     : http://%s:%s/planet%s\n' "$PUBLIC_IPV4" "$FILES_PORT" "$PLANET_QS"
printf '  健康检查        : http://%s:%s/healthz\n' "$PUBLIC_IPV4" "$FILES_PORT"
printf '  moons 列表      : http://%s:%s/moons%s\n' "$PUBLIC_IPV4" "$FILES_PORT" "$PLANET_QS"
if [ -n "$DOWNLOAD_TOKEN" ]; then
	printf '  下载凭据        : ?token=%s 或 Authorization: Bearer ****（Android 只发 Bearer 头）\n' "$DOWNLOAD_TOKEN"
	printf '                    完整 token 见 compose/.env 的 DOWNLOAD_TOKEN\n'
else
	printf '  下载凭据        : 未启用（任何人可下载 planet）\n'
fi
echo "  防火墙必须放行  :"
printf '                    %s/tcp %s/udp   ZeroTier peer + API/controller\n' "$ZT_PORT" "$ZT_PORT"
printf '                    %s/tcp          planet/moon 下载\n' "$FILES_PORT"
printf '                    %s/tcp          ZTNet 面板（用 TLS 时可只对内网开放）\n' "$ZTNET_PORT"
[ -n "$TLS_DOMAIN" ] && printf '                    80/tcp 443/tcp 443/udp   Caddy ACME + HTTPS\n'
echo "  下一步          :"
echo "                    1) 浏览器打开面板，注册第一个管理员账号"
echo "                    2) scripts/stack-status.sh 看状态与 planet world id"
echo "                    3) scripts/e2e-verify.sh 跑端到端验收"
echo "                    4) 客户端装 planet：见 clients/ 与 README.md"
echo "==================================================="

if [ "$HEALTH_FAIL" -eq 1 ]; then
	warn "有服务没到 healthy，用 scripts/stack-status.sh 与 docker logs 排查"
	exit 1
fi
ok "部署完成"
check_env_perms
