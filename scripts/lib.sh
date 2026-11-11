#!/usr/bin/env bash
# zerotier-planet 脚本公共函数：路径解析、.env 读写、compose 包装、日志。
# 只被同目录下的 deploy.sh / stack-status.sh / e2e-verify.sh source，不单独执行。
# shellcheck shell=bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_DIR="${STACK_DIR}/compose"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
ENV_FILE="${COMPOSE_DIR}/.env"
ENV_EXAMPLE="${COMPOSE_DIR}/.env.example"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[36m'; C_OFF=$'\033[0m'
else
	C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_OFF=''
fi

log()  { printf '%s[zerotier-planet]%s %s\n' "$C_BLUE" "$C_OFF" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GREEN" "$C_OFF" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }

# docker compose 的固定调用方式：始终用同一份 compose 文件与 .env
compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

require_docker() {
	command -v docker >/dev/null 2>&1 || die "找不到 docker，先安装 Docker Engine 或 Docker Desktop"
	docker info >/dev/null 2>&1 || die "连不上 docker daemon（当前用户是否在 docker 组？）"
	docker compose version >/dev/null 2>&1 || die "缺少 docker compose v2 插件（docker compose version 失败）"
}

# env_get KEY -> 打印 .env 里该键的值（没有则空）
env_get() {
	local key="$1"
	[ -f "$ENV_FILE" ] || return 0
	K="$key" awk 'BEGIN{k=ENVIRON["K"]} index($0,k"=")==1 {v=substr($0,length(k)+2)} END{if(v!="")print v}' "$ENV_FILE"
}

# env_set KEY VALUE -> 就地改写或追加；值不经过 shell 展开，也不会被当成正则
env_set() {
	local key="$1" val="$2" tmp="${ENV_FILE}.tmp.$$"
	if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
		K="$key" V="$val" awk 'BEGIN{k=ENVIRON["K"];v=ENVIRON["V"]} index($0,k"=")==1 {print k"="v; next} {print}' "$ENV_FILE" >"$tmp"
		mv "$tmp" "$ENV_FILE"
	else
		printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
	fi
	chmod 600 "$ENV_FILE"
}

# 有些文件系统（WSL 的 /mnt/d DrvFs、Windows 共享盘）不生效 chmod，
# 这里在写完 .env 后显式核对一次权限，做不到就说出来，别让人误以为已经 600。
check_env_perms() {
	[ -f "$ENV_FILE" ] || return 0
	local mode
	mode="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo '?')"
	case "$mode" in
		600|'?') return 0 ;;
		*) warn "compose/.env 实际权限是 $mode 而不是 600：当前文件系统（多半是 WSL 的 /mnt/d DrvFs）不支持 chmod；架在 Linux 原生文件系统上时会自动是 600，请确认这份 .env 没有被同步到公共位置" ;;
	esac
}

# rand_hex N -> N 字节随机十六进制串（不含 shell 特殊字符，安全写回 .env）
rand_hex() {
	local n="${1:-32}"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex "$n"
	else
		od -An -tx1 -N "$n" /dev/urandom | tr -d ' \n'
	fi
}

is_ipv4() {
	local ip="$1"
	[[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
	local o
	for o in "${BASH_REMATCH[@]:1}"; do
		[ "$((10#$o))" -le 255 ] || return 1
	done
	return 0
}

is_ipv6() {
	local ip="$1"
	[[ "$ip" == *:* ]] || return 1
	[[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
	return 0
}

is_port() {
	[[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# container_health NAME -> healthy / unhealthy / starting / absent
container_health() {
	docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$1" 2>/dev/null || echo absent
}

# wait_healthy NAME TIMEOUT_SECONDS
wait_healthy() {
	local name="$1" timeout="${2:-300}" waited=0 status
	while [ "$waited" -lt "$timeout" ]; do
		status="$(container_health "$name")"
		case "$status" in
			healthy) return 0 ;;
			unhealthy) warn "$name 状态 unhealthy，见 docker logs $name"; return 1 ;;
			absent) return 1 ;;
		esac
		sleep 3; waited=$((waited + 3))
	done
	warn "$name 在 ${timeout}s 内没有变成 healthy（当前 $status）"
	return 1
}

# 把 .env 里关心的值装进变量，供打印用（只读，不改文件）
stack_summary_vars() {
	PUBLIC_IPV4="$(env_get PUBLIC_IPV4)"
	PUBLIC_IPV6="$(env_get PUBLIC_IPV6)"
	ZT_PORT="$(env_get ZT_PORT)";     ZT_PORT="${ZT_PORT:-9994}"
	FILES_PORT="$(env_get FILES_PORT)"; FILES_PORT="${FILES_PORT:-3000}"
	ZTNET_PORT="$(env_get ZTNET_PORT)"; ZTNET_PORT="${ZTNET_PORT:-3001}"
	DOWNLOAD_TOKEN="$(env_get DOWNLOAD_TOKEN)"
	TLS_DOMAIN="$(env_get TLS_DOMAIN)"
	NEXTAUTH_URL="$(env_get NEXTAUTH_URL)"
}
