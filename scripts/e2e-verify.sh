#!/usr/bin/env bash
# 端到端验收：控制器建网 -> 客户端容器下载并安装 planet -> join -> 断言能看到 PLANET 根节点。
#
#   ./e2e-verify.sh            用正在运行的栈（planet 端点 = .env 里的 PUBLIC_IPV4:ZT_PORT）
#   ./e2e-verify.sh --local    另外做一次自包含冒烟：临时 bridge 里起一个一次性 planet，
#                              不依赖公网可达性（适合本机/CI 验证镜像与控制器链路）
#   ./e2e-verify.sh --keep     结束后不删除测试网络
#
# 依赖：docker、curl、python3（宿主）；镜像 ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<PLANET_NODE_TAG>（既做根节点也做客户端，可用 PLANET_NODE_IMAGE 覆盖）。
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MODE_STACK=1
MODE_LOCAL=0
KEEP=0
GIVEN_IP=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--local) MODE_LOCAL=1; MODE_STACK=0; shift ;;
		--stack) MODE_STACK=1; MODE_LOCAL=0; shift ;;
		--keep)  KEEP=1; shift ;;
		--ip)    GIVEN_IP="${2:?--ip 需要值}"; shift 2 ;;
		-h|--help) sed -n '2,12p' "$0"; exit 0 ;;
		*) die "未知参数: $1（--help 看用法）" ;;
	esac
done

require_docker
[ -f "$ENV_FILE" ] || die "缺少 $ENV_FILE：先跑 scripts/deploy.sh -i <公网IP>"
stack_summary_vars
PLANET_TAG="${PLANET_NODE_TAG:-$(env_get PLANET_NODE_TAG)}"
PLANET_TAG="${PLANET_TAG:-1.16.2}"
PLANET_IMAGE="${PLANET_NODE_IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-planet:${PLANET_TAG}}"
docker image inspect "$PLANET_IMAGE" >/dev/null 2>&1 || die "本地没有镜像 $PLANET_IMAGE（docker pull 它，或在本机 planet-node/build.sh 构建）"

WORKDIR="$(mktemp -d)"
cleanup() {
	[ "$KEEP" -eq 1 ] || {
		docker rm -f zt-e2e-client >/dev/null 2>&1 || true
		docker rm -f zt-e2e-planet >/dev/null 2>&1 || true
		docker network rm zt-e2e-net >/dev/null 2>&1 || true
		docker volume rm zt-e2e-planet-data >/dev/null 2>&1 || true
	}
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

FAIL=0
step() { printf '\n==== %s ====\n' "$*"; }

# ---------------------------------------------------------------- 控制器 API（仅 stack 模式）
if [ "$MODE_STACK" -eq 1 ]; then
CTRL="http://127.0.0.1:${ZT_PORT:-9994}"
TOKEN="$(docker exec zt-stack-zerotier cat /var/lib/zerotier-one/authtoken.secret 2>/dev/null || true)"
[ -n "$TOKEN" ] || die "读不到 authtoken.secret：栈没起来？"

step "控制器 /status"
STATUS_JSON="$(curl -s -m 8 -H "X-ZT1-Auth: $TOKEN" "$CTRL/status")"
printf '%s\n' "$STATUS_JSON" | head -c 400; echo
NODE_ADDR="$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["address"])')"
[ -n "$NODE_ADDR" ] || die "控制器没有返回 address"
ok "控制器地址 $NODE_ADDR，版本 $(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version"))')"

step "建网：POST /controller/network/<addr>______（ZTNet 用的同一条 legacy 路径）"
CREATE_BODY='{"name":"e2e-verify","private":false,"v4AssignMode":{"zt":true},"ipAssignmentPools":[{"ipRangeStart":"10.147.230.1","ipRangeEnd":"10.147.230.254"}]}'
CREATE_JSON="$(curl -s -m 15 -X POST -H "X-ZT1-Auth: $TOKEN" -H 'Content-Type: application/json' -d "$CREATE_BODY" "$CTRL/controller/network/${NODE_ADDR}______")"
printf '%s\n' "$CREATE_JSON" | head -c 500; echo
NWID="$(printf '%s' "$CREATE_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
[ -n "$NWID" ] || { warn "legacy 建网路径没返回 id"; FAIL=1; }
if [ -n "$NWID" ]; then
	ok "网络已创建: $NWID"
	step "读回网络配置 GET /controller/network/$NWID"
	READ_JSON="$(curl -s -m 8 -H "X-ZT1-Auth: $TOKEN" "$CTRL/controller/network/$NWID")"
	printf '%s\n' "$READ_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  name=%s private=%s routes=%s" % (d.get("name"), d.get("private"), len(d.get("routes",[]))))'
	step "网络列表 GET /controller/network"
	curl -s -m 8 -H "X-ZT1-Auth: $TOKEN" "$CTRL/controller/network"; echo
fi
fi  # end stack 模式

# ---------------------------------------------------------------- 客户端脚本
write_client_script() {
	cat >"$WORKDIR/client.sh" <<'EOS'
set -euo pipefail
echo "CLIENT STEP: 下载 planet（Authorization: Bearer，与 Android 客户端一致）"
mkdir -p /var/lib/zerotier-one
python3 - <<'PY'
import hashlib, os, urllib.request
url, tok = os.environ["PLANET_URL"], os.environ["PLANET_TOKEN"]
req = urllib.request.Request(url)
if tok:
    req.add_header("Authorization", "Bearer " + tok)
data = urllib.request.urlopen(req, timeout=20).read()
open("/var/lib/zerotier-one/planet", "wb").write(data)
print("downloaded %d bytes sha256=%s" % (len(data), hashlib.sha256(data).hexdigest()))
PY
cli_sum() { sha256sum /var/lib/zerotier-one/planet | awk '{print $1}'; }
[ "$(cli_sum)" = "$PLANET_SHA" ] || { echo "SHA MISMATCH: client=$(cli_sum) server=$PLANET_SHA" >&2; exit 3; }
echo "planet sha256 matches server"

echo "CLIENT STEP: 启动 zerotier-one 并 join"
zerotier-one >/var/log/zerotier.log 2>&1 &
for i in $(seq 1 90); do zerotier-cli info >/dev/null 2>&1 && break; sleep 1; done
zerotier-cli info
zerotier-cli join "$NWID"
status=""
for i in $(seq 1 90); do
	status="$(zerotier-cli listnetworks 2>/dev/null | awk -v id="$NWID" 'index($0,id){for(i=1;i<=NF;i++) if ($i ~ /^(OK|ACCESS_DENIED|REQUESTING_CONFIGURATION|NOT_FOUND|PORT_ERROR|AUTHENTICATION_REQUIRED)$/) {print $i; exit}}')"
	[ "$status" = OK ] && break
	sleep 1
done
echo "network status: ${status:-<none>}"
echo "--- zerotier-cli peers ---"
zerotier-cli peers || true
echo "--- zerotier-cli listnetworks ---"
zerotier-cli listnetworks || true
[ "$status" = OK ] || { echo "network did not reach OK (status=$status)" >&2; exit 4; }
EOS
}

run_client() { # $1 = planet-url, $2 = token, $3 = planet sha256, $4 = network id
	write_client_script
	docker rm -f zt-e2e-client >/dev/null 2>&1 || true
	docker run --rm --name zt-e2e-client \
		--cap-add NET_ADMIN --device /dev/net/tun \
		-e PLANET_URL="$1" -e PLANET_TOKEN="$2" -e PLANET_SHA="$3" -e NWID="$4" \
		-v "$WORKDIR/client.sh:/client.sh:ro" \
		${NET_ARG:+"${NET_ARG[@]}"} \
		--entrypoint /bin/bash "$PLANET_IMAGE" /client.sh
}

# ---------------------------------------------------------------- A. 用正在运行的栈
if [ "$MODE_STACK" -eq 1 ]; then
	step "A. 用运行中的栈做端到端（planet 端点 ${PUBLIC_IPV4:-?}:${ZT_PORT:-9994}）"
	[ -n "${PUBLIC_IPV4:-}" ] || die ".env 里没有 PUBLIC_IPV4"
	SERVER_SHA="$(docker exec zt-stack-zerotier sha256sum /var/lib/zerotier-one/planet | awk '{print $1}')"
	DL_URL="http://${PUBLIC_IPV4}:${FILES_PORT:-3000}/planet"
	# 客户端容器里用公网地址下载，顺带验证发布端口
	NET_ARG=()
	if run_client "$DL_URL" "$DOWNLOAD_TOKEN" "$SERVER_SHA" "$NWID" >"$WORKDIR/client.log" 2>&1; then
		ok "客户端 join 成功"
	else
		RC=$?
		warn "客户端流程退出码 $RC，输出如下："
		sed 's/^/    /' "$WORKDIR/client.log" | tail -40
		FAIL=1
	fi
	sed 's/^/  | /' "$WORKDIR/client.log" | tail -45
	if grep -qE '\bPLANET\b' "$WORKDIR/client.log"; then
		ok "peers 里能看到 PLANET 角色的根节点"
	else
		warn "peers 输出里没有 PLANET 角色（见上面的日志）"; FAIL=1
	fi
fi

# ---------------------------------------------------------------- B. 自包含冒烟
if [ "$MODE_LOCAL" -eq 1 ]; then
	step "B. 自包含冒烟：临时 bridge 上的一次性 planet（不依赖公网）"
	docker rm -f zt-e2e-planet >/dev/null 2>&1 || true
	docker network rm zt-e2e-net >/dev/null 2>&1 || true
	docker network create --subnet 172.30.77.0/24 zt-e2e-net >/dev/null
	docker run -d --name zt-e2e-planet --network zt-e2e-net --ip 172.30.77.10 \
		-e PUBLIC_IPV4=172.30.77.10 -e ZT_PORT=9993 -e DOWNLOAD_TOKEN=e2etok \
		-v zt-e2e-planet-data:/var/lib/zerotier-one "$PLANET_IMAGE" >/dev/null
	for i in $(seq 1 90); do
		[ "$(container_health zt-e2e-planet)" = healthy ] && break
		sleep 1
	done
	[ "$(container_health zt-e2e-planet)" = healthy ] || { warn "一次性 planet 没起健康"; docker logs zt-e2e-planet | tail -20; FAIL=1; }
	L_SHA="$(docker exec zt-e2e-planet sha256sum /var/lib/zerotier-one/planet | awk '{print $1}')"
	L_ADDR="$(docker exec zt-e2e-planet python3 -c 'import json,urllib.request,os;t=open("/var/lib/zerotier-one/authtoken.secret").read().strip();r=urllib.request.Request("http://127.0.0.1:9993/status");r.add_header("X-ZT1-Auth",t);print(json.load(urllib.request.urlopen(r,timeout=5))["address"])')"
	L_CREATE="$(docker exec -i zt-e2e-planet python3 - "$L_ADDR" <<'PY'
import json, sys, urllib.request
tok = open("/var/lib/zerotier-one/authtoken.secret").read().strip()
body = json.dumps({"name": "e2e-local", "private": False,
                   "v4AssignMode": {"zt": True},
                   "ipAssignmentPools": [{"ipRangeStart": "10.147.231.1", "ipRangeEnd": "10.147.231.254"}]}).encode()
req = urllib.request.Request("http://127.0.0.1:9993/controller/network/%s______" % sys.argv[1], data=body, method="POST")
req.add_header("X-ZT1-Auth", tok); req.add_header("Content-Type", "application/json")
print(urllib.request.urlopen(req, timeout=15).read().decode())
PY
)"
	printf '%s\n' "$L_CREATE" | head -c 300; echo
	L_NWID="$(printf '%s' "$L_CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
	if [ -z "$L_NWID" ]; then
		warn "自包含建网失败"; FAIL=1
	else
		ok "自包含网络: $L_NWID"
		NET_ARG=(--network zt-e2e-net --ip 172.30.77.11)
		if run_client "http://172.30.77.10:3000/planet" "e2etok" "$L_SHA" "$L_NWID" >"$WORKDIR/client-local.log" 2>&1; then
			ok "自包含客户端 join 成功"
		else
			warn "自包含客户端退出码 $?"; FAIL=1
		fi
		sed 's/^/  | /' "$WORKDIR/client-local.log" | tail -45
		grep -qE '\bPLANET\b' "$WORKDIR/client-local.log" && ok "自包含：peers 出现 PLANET" || { warn "自包含：peers 没有 PLANET"; FAIL=1; }
	fi
fi

# ---------------------------------------------------------------- 收尾
step "清理测试网络"
if [ -n "${NWID:-}" ] && [ -n "${TOKEN:-}" ]; then
	DEL_CODE="$(curl -s -o /dev/null -m 8 -w '%{http_code}' -X DELETE -H "X-ZT1-Auth: $TOKEN" "$CTRL/controller/network/$NWID")"
	echo "DELETE /controller/network/$NWID -> HTTP $DEL_CODE"
fi
if [ -n "$FAIL" ] && [ "$FAIL" -ne 0 ]; then
	warn "端到端验收有失败项，见上面的逐段输出"
	exit 1
fi
ok "端到端验收通过"
