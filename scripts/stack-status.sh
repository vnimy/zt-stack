#!/usr/bin/env bash
# zerotier-planet 状态总览：服务健康、planet world id/时间戳、controller 可用性、下载端点。
# 只读，不改任何东西；健康项失败时退出码为 1。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

require_docker
[ -f "$ENV_FILE" ] || die "缺少 $ENV_FILE：先跑 scripts/deploy.sh -i <公网IP>"

stack_summary_vars

# ---------------------------------------------------------------- 服务状态
echo "================ 服务状态 ================"
compose ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}' || true
echo

FAIL=0
for svc in postgres zerotier ztnet; do
	health="$(container_health "zerotier-planet-$svc")"
	printf '  %-10s %s\n' "$svc" "$health"
	[ "$health" = healthy ] || [ "$health" = running ] || FAIL=1
done
echo

# ---------------------------------------------------------------- 面板
PANEL_CODE="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$ZTNET_PORT/auth/login" || echo 000)"
printf 'ZTNet 面板      http://127.0.0.1:%s/auth/login -> HTTP %s\n' "$ZTNET_PORT" "$PANEL_CODE"
case "$PANEL_CODE" in 2*|3*) : ;; *) FAIL=1 ;; esac

# ---------------------------------------------------------------- 下载端点
echo
echo "================ planet 下载端点 ================"
HZ="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/healthz" || echo 000)"
printf '  GET /healthz        -> HTTP %s\n' "$HZ"
[ "$HZ" = 200 ] || FAIL=1

CONTAINER_SUM="$(docker exec zerotier-planet-zerotier sha256sum /var/lib/zerotier-one/planet 2>/dev/null | awk '{print $1}')"
TMP_PLANET="$(mktemp)"
if [ -n "$DOWNLOAD_TOKEN" ]; then
	NOAUTH="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet" || echo 000)"
	CODE="$(curl -s -o "$TMP_PLANET" -m 8 -w '%{http_code}' -H "Authorization: Bearer $DOWNLOAD_TOKEN" "http://127.0.0.1:$FILES_PORT/planet" || echo 000)"
	QSLUG="$(curl -s -o /dev/null -m 8 -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet?token=$DOWNLOAD_TOKEN" || echo 000)"
	printf '  GET /planet (无凭据)-> HTTP %s（token 已启用，期望 401）\n' "$NOAUTH"
	printf '  GET /planet (Bearer)-> HTTP %s\n' "$CODE"
	printf '  GET /planet (?token)-> HTTP %s\n' "$QSLUG"
	[ "$NOAUTH" = 401 ] || warn "无凭据访问返回 $NOAUTH，期望 401"
	[ "$CODE" = 200 ] && [ "$QSLUG" = 200 ] || FAIL=1
else
	CODE="$(curl -s -o "$TMP_PLANET" -m 8 -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet" || echo 000)"
	printf '  GET /planet         -> HTTP %s（未启用 token）\n' "$CODE"
	[ "$CODE" = 200 ] || FAIL=1
fi
DL_SUM="$(sha256sum "$TMP_PLANET" | awk '{print $1}')"
SIZE="$(wc -c <"$TMP_PLANET" | tr -d ' ')"
rm -f "$TMP_PLANET"
printf '  下载 sha256        %s\n  容器内 sha256      %s\n  文件大小           %s 字节\n' "$DL_SUM" "$CONTAINER_SUM" "$SIZE"
if [ -n "$CONTAINER_SUM" ] && [ "$DL_SUM" = "$CONTAINER_SUM" ]; then
	ok "下载到的 planet 与容器内文件一致"
else
	warn "下载 sha256 与容器内不一致（或容器内文件不可读）"; FAIL=1
fi

# ---------------------------------------------------------------- planet 元数据
echo
echo "================ planet (world) ================"
docker exec -i zerotier-planet-zerotier python3 - <<'PY' || FAIL=1
import hashlib, struct, sys, datetime
p = "/var/lib/zerotier-one/planet"
try:
    d = open(p, "rb").read()
except OSError as e:
    print("  读不到 %s: %s" % (p, e)); sys.exit(1)
TYPES = {1: "planet", 2: "moon"}
if len(d) < 17:
    print("  文件只有 %d 字节，不是有效的 world" % len(d)); sys.exit(1)
wtype = TYPES.get(d[0], "unknown(%d)" % d[0])
wid = struct.unpack(">Q", d[1:9])[0]
ts = struct.unpack(">Q", d[9:17])[0]
stamp = datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
print("  type            %s" % wtype)
print("  world id        %d (0x%08x)" % (wid, wid))
print("  timestamp       %d  (%s)" % (ts, stamp))
print("  size            %d 字节" % len(d))
print("  sha256          %s" % hashlib.sha256(d).hexdigest())
PY
echo "  容器内 mkworld verify（若镜像带该工具）："
docker exec zerotier-planet-zerotier sh -c 'command -v mkworld >/dev/null && mkworld verify /var/lib/zerotier-one/planet 2>&1 | sed "s/^/    /" || echo "    (镜像内没有 mkworld，已用上面的字节解析)"' || true

# ---------------------------------------------------------------- controller
echo
echo "================ controller (9993) ================"
TOKEN="$(docker exec zerotier-planet-zerotier cat /var/lib/zerotier-one/authtoken.secret 2>/dev/null || true)"
if [ -z "$TOKEN" ]; then
	warn "读不到 authtoken.secret，跳过 controller 检查"; FAIL=1
else
	STATUS_JSON="$(curl -s -m 8 -H "X-ZT1-Auth: $TOKEN" "http://127.0.0.1:$ZT_PORT/status" || true)"
	if [ -z "$STATUS_JSON" ]; then
		warn "GET http://127.0.0.1:$ZT_PORT/status 无响应"; FAIL=1
	else
		printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  node address    %s" % d.get("address")); print("  version         %s" % d.get("version")); print("  online          %s" % d.get("online")); print("  tcpFallback     %s" % d.get("tcpFallbackActive"))' || FAIL=1
		NETS="$(curl -s -m 8 -H "X-ZT1-Auth: $TOKEN" "http://127.0.0.1:$ZT_PORT/controller/network" || true)"
		echo "  控制器上的网络  $NETS"
	fi
fi

# ---------------------------------------------------------------- 镜像与体积
echo
echo "================ 镜像 ================"
compose images 2>/dev/null || true

exit "$FAIL"
