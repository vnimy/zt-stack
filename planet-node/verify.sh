#!/bin/bash
# Single-container acceptance run for the zerotier-planet image.
#
#   ./verify.sh            # build must already exist (./build.sh)
#
# Exercises, in order: node identity/version, planet file on disk, planet world
# id/timestamp through the management API, embedded controller create+read,
# download service (token ok / token wrong / healthz / index), and idempotence
# across a container restart.
set -uo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2}"
NAME="${NAME:-zt-planet-verify}"
VOL="${VOL:-zt-planet-verify-data}"
# host-side mappings (inside the container it is always 3000 and 9993). These are
# deliberately not 3000/9994 so the script can run next to a live zerotier-planet compose.
FILES_PORT="${FILES_PORT:-3920}"
API_PORT="${API_PORT:-13920}"
DOWNLOAD_TOKEN="${DOWNLOAD_TOKEN:-verify-token-abc123}"
PUBLIC_IPV4="${PUBLIC_IPV4:-203.0.113.10}"
TMP="$(mktemp -d)"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
head1() { printf '\n=== %s ===\n' "$*"; }

cleanup() {
	docker rm -f "$NAME" >/dev/null 2>&1
	rm -rf "$TMP"
}
trap cleanup EXIT

wait_api() {
	for _ in $(seq 1 120); do
		if [ -s "$TMP/token" ] && curl -fsS -m 2 -H "X-ZT1-Auth: $(cat "$TMP/token")" "http://127.0.0.1:$API_PORT/status" >/dev/null 2>&1; then
			return 0
		fi
		if docker exec "$NAME" test -s /var/lib/zerotier-one/authtoken.secret 2>/dev/null; then
			docker exec "$NAME" cat /var/lib/zerotier-one/authtoken.secret >"$TMP/token" 2>/dev/null
		fi
		sleep 1
	done
	return 1
}

head1 "start container (image $IMAGE)"
docker rm -f "$NAME" >/dev/null 2>&1
docker volume rm "$VOL" >/dev/null 2>&1
docker run -d --name "$NAME" \
	-e PUBLIC_IPV4="$PUBLIC_IPV4" \
	-e DOWNLOAD_TOKEN="$DOWNLOAD_TOKEN" \
	-p "$FILES_PORT:3000" -p "$API_PORT:9993" -p "$API_PORT:9993/udp" \
	-v "$VOL:/var/lib/zerotier-one" \
	"$IMAGE" >/dev/null || { bad "docker run"; exit 1; }

wait_api && ok "management API answers on 127.0.0.1:$API_PORT" || { bad "management API never came up"; docker logs --tail 60 "$NAME"; exit 1; }
TOK="$(cat "$TMP/token")"
echo "authtoken.secret -> $TOK"
docker logs --tail 25 "$NAME" 2>&1 | sed 's/^/  | /'

# ---------------------------------------------------------------- 2. identity
head1 "2a. zerotier-cli info"
INFO="$(docker exec "$NAME" zerotier-cli info 2>&1)"
echo "  $INFO"
echo "$INFO" | grep -q '200 info ' && ok "zerotier-cli info returns 200 info" || bad "zerotier-cli info: $INFO"
NODEID="$(echo "$INFO" | awk '{print $3}')"

head1 "2b. planet file read back (mkworld verify, identity match)"
VERIFY="$(docker exec "$NAME" mkworld verify /var/lib/zerotier-one/planet 2>&1)"
echo "$VERIFY" | sed 's/^/  /'
echo "$VERIFY" | grep -q 'signature_valid=true' && ok "planet signature verifies" || bad "planet signature does not verify"
echo "$VERIFY" | grep -q "root\[0\].identity=.*" && ok "planet carries one root identity" || bad "no root identity in planet"
IDENTITY_PUB="$(docker exec "$NAME" cat /var/lib/zerotier-one/identity.public)"
echo "  identity.public     = $IDENTITY_PUB"
ROOT_ID="$(echo "$VERIFY" | sed -n 's/^root\[0\].identity=//p')"
[ "$ROOT_ID" = "$IDENTITY_PUB" ] && ok "planet root identity equals node identity ($NODEID)" || bad "planet root identity ($ROOT_ID) != node identity ($IDENTITY_PUB)"
echo "$VERIFY" | grep -q "root\[0\].endpoint\[0\]=$PUBLIC_IPV4/" && ok "planet stableEndpoint advertises $PUBLIC_IPV4:<ZT_PORT>" || bad "planet stableEndpoint is not $PUBLIC_IPV4:<ZT_PORT>"
echo "$VERIFY" | grep -q 'signing_key=' && ok "planet is signed by a persistent world key" || bad "planet has no signing key"

# ------------------------------------------------------------------ 3. status
head1 "3. GET /status -> planetWorldId / planetWorldTimestamp"
STATUS="$(curl -fsS -H "X-ZT1-Auth: $TOK" "http://127.0.0.1:$API_PORT/status")"
echo "$STATUS" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  planetWorldId        =", d.get("planetWorldId")); print("  planetWorldTimestamp =", d.get("planetWorldTimestamp")); print("  version              =", d.get("version")); print("  address              =", d.get("address"))'
WID="$(echo "$STATUS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldId", 0))')"
WTS="$(echo "$STATUS" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldTimestamp", 0))')"
[ "$WID" != "0" ] && ok "planetWorldId=$WID" || bad "planetWorldId is 0 (planet not loaded)"
[ "$WTS" != "0" ] && ok "planetWorldTimestamp=$WTS" || bad "planetWorldTimestamp is 0"

# -------------------------------------------------------------- 4. controller
head1 "4. embedded controller: create + read a network"
# ZeroTier 1.16.2 (nonfree/controller/EmbeddedNetworkController.cpp) exposes the
# network CRUD API as:
#   POST /controller/network              -> create, the controller picks a 16-hex id
#   GET  /controller/network/<16 hex id>  -> read
# There is no "create with an id of my choosing" endpoint: the path-based create is
# the legacy /controller/network/<nodeid>______ form, and the id path regexp only
# accepts 16 hex characters, so POST /controller/network/<10 hex> is a 404 by design.
echo "  (1.16.2 assigns the network id itself; 16 hex, not 10)"
CODE="$(curl -s -o "$TMP/net.json" -w '%{http_code}' -X POST \
	-H "X-ZT1-Auth: $TOK" -H 'Content-Type: application/json' \
	--data '{"name":"w1-acceptance","private":true}' \
	"http://127.0.0.1:$API_PORT/controller/network")"
echo "  POST /controller/network -> $CODE"
NWID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$TMP/net.json" 2>/dev/null)"
head -c 300 "$TMP/net.json"; echo
[ "$CODE" = "200" ] && ok "controller created network $NWID" || bad "controller create returned $CODE"
CODE2="$(curl -s -o "$TMP/net2.json" -w '%{http_code}' -H "X-ZT1-Auth: $TOK" "http://127.0.0.1:$API_PORT/controller/network/$NWID")"
echo "  GET  /controller/network/$NWID -> $CODE2"
head -c 300 "$TMP/net2.json"; echo
[ "$CODE2" = "200" ] && ok "controller reads network back" || bad "controller read returned $CODE2"
python3 - "$TMP/net2.json" <<'PY' && ok "controller read-back carries the name it was created with" || bad "controller read-back does not match"
import json
import sys
try:
    with open(sys.argv[1]) as fp:
        cfg = json.load(fp)
except Exception:
    sys.exit(1)
sys.exit(0 if cfg.get("name") == "w1-acceptance" else 1)
PY

# --------------------------------------------------------------- 5. downloads
head1 "5. download service"
INSIDE_SHA="$(docker exec "$NAME" sha256sum /var/lib/zerotier-one/planet | cut -d' ' -f1)"
CODE="$(curl -s -o "$TMP/planet.dl" -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet?token=$DOWNLOAD_TOKEN")"
OUTSIDE_SHA="$(sha256sum "$TMP/planet.dl" | cut -d' ' -f1)"
echo "  GET /planet?token=...            -> $CODE"
echo "  sha256 inside container          = $INSIDE_SHA"
echo "  sha256 downloaded                = $OUTSIDE_SHA"
[ "$CODE" = "200" ] && ok "/planet with valid token returns 200" || bad "/planet valid token -> $CODE"
[ "$INSIDE_SHA" = "$OUTSIDE_SHA" ] && ok "/planet download matches the container file" || bad "/planet digest differs"

CODE_AUTH="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $DOWNLOAD_TOKEN" "http://127.0.0.1:$FILES_PORT/planet")"
[ "$CODE_AUTH" = "200" ] && ok "/planet accepts Authorization: Bearer" || bad "/planet Bearer auth -> $CODE_AUTH"

CODE_BAD="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet?token=wrong")"
[ "$CODE_BAD" = "401" ] && ok "/planet with wrong token returns 401" || bad "/planet wrong token -> $CODE_BAD"

CODE_H="$(curl -s -o "$TMP/health" -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/healthz")"
[ "$CODE_H" = "200" ] && ok "/healthz returns 200 ($(cat "$TMP/health"))" || bad "/healthz -> $CODE_H"

CODE_I="$(curl -s -o "$TMP/index.html" -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/?token=$DOWNLOAD_TOKEN")"
[ "$CODE_I" = "200" ] && grep -q 'ZeroTier planet node' "$TMP/index.html" && ok "/ index page returns 200 and is readable" || bad "/ index page -> $CODE_I"

CODE_M="$(curl -s -o "$TMP/moons.json" -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/moons?token=$DOWNLOAD_TOKEN")"
MOONS="$(cat "$TMP/moons.json" 2>/dev/null)"
echo "  GET /moons -> $CODE_M $MOONS"
echo "$MOONS" | grep -q '\.moon' && ok "/moons lists the generated moon" || bad "/moons does not list a moon"

# ------------------------------------------------------------- 6. idempotence
head1 "6. restart the container: world id and identity must not change"
docker restart "$NAME" >/dev/null
rm -f "$TMP/token"
wait_api && ok "API is back after restart" || { bad "API did not come back after restart"; docker logs --tail 40 "$NAME"; }
TOK2="$(cat "$TMP/token")"
STATUS2="$(curl -fsS -H "X-ZT1-Auth: $TOK2" "http://127.0.0.1:$API_PORT/status")"
WID2="$(echo "$STATUS2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldId", 0))')"
WTS2="$(echo "$STATUS2" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldTimestamp", 0))')"
IDENTITY2="$(docker exec "$NAME" cat /var/lib/zerotier-one/identity.public)"
echo "  before: worldId=$WID ts=$WTS identity=$IDENTITY_PUB"
echo "  after : worldId=$WID2 ts=$WTS2 identity=$IDENTITY2"
[ "$WID" = "$WID2" ] && [ "$WTS" = "$WTS2" ] && ok "planet world id/timestamp unchanged" || bad "planet world changed across restart"
[ "$IDENTITY_PUB" = "$IDENTITY2" ] && ok "node identity unchanged" || bad "node identity changed across restart"
CODE_P2="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet?token=$DOWNLOAD_TOKEN")"
[ "$CODE_P2" = "200" ] && ok "download service still serves /planet after restart" || bad "/planet after restart -> $CODE_P2"

# ------------------------------------------------- 7. REGENERATE_WORLD=1 (new IP)
head1 "7. REGENERATE_WORLD=1: new public IP, same identity, same network IDs"
NEW_IP="203.0.113.20"
BEFORE_WTS="$WTS"
BEFORE_TOKEN="$(docker exec "$NAME" cat /var/lib/zerotier-one/authtoken.secret)"
BEFORE_MOON="$(docker exec "$NAME" sh -c 'ls /var/lib/zerotier-one/moons.d | tr "\n" " "')"
echo "  before: identity=${IDENTITY_PUB%%:*} worldId=$WID ts=$WTS endpoint=$PUBLIC_IPV4 moon=$BEFORE_MOON network=$NWID"

docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" \
	-e PUBLIC_IPV4="$NEW_IP" -e ZT_PORT=9994 -e DOWNLOAD_TOKEN="$DOWNLOAD_TOKEN" -e REGENERATE_WORLD=1 \
	-p "$FILES_PORT:3000" -p "$API_PORT:9993" -p "$API_PORT:9993/udp" \
	-v "$VOL:/var/lib/zerotier-one" \
	"$IMAGE" >/dev/null
rm -f "$TMP/token"
wait_api && ok "container came up with REGENERATE_WORLD=1" || { bad "container did not come up with REGENERATE_WORLD=1"; docker logs --tail 40 "$NAME"; }
docker logs "$NAME" 2>&1 | grep -a 'entrypoint:' | sed 's/^/  | /'
TOK3="$(cat "$TMP/token")"

AFTER_ID="$(docker exec "$NAME" cat /var/lib/zerotier-one/identity.public)"
AFTER_TOKEN="$(docker exec "$NAME" cat /var/lib/zerotier-one/authtoken.secret)"
AFTER_MOON="$(docker exec "$NAME" sh -c 'ls /var/lib/zerotier-one/moons.d | tr "\n" " "')"
STATUS3="$(curl -fsS -H "X-ZT1-Auth: $TOK3" "http://127.0.0.1:$API_PORT/status")"
WID3="$(echo "$STATUS3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldId", 0))')"
WTS3="$(echo "$STATUS3" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldTimestamp", 0))')"
VERIFY3="$(docker exec "$NAME" mkworld verify /var/lib/zerotier-one/planet 2>&1)"
echo "  after : identity=${AFTER_ID%%:*} worldId=$WID3 ts=$WTS3 moon=$AFTER_MOON"
echo "$VERIFY3" | sed 's/^/  | /'

[ "$IDENTITY_PUB" = "$AFTER_ID" ] && ok "(a) node identity survived REGENERATE_WORLD ($(echo "$AFTER_ID" | cut -d: -f1))" || bad "(a) identity changed: $IDENTITY_PUB -> $AFTER_ID"
[ "$BEFORE_TOKEN" = "$AFTER_TOKEN" ] && ok "(b) authtoken.secret survived REGENERATE_WORLD" || bad "(b) authtoken.secret changed"
[ "$WID" = "$WID3" ] && ok "(a) planet world id unchanged ($WID3)" || bad "(a) world id changed: $WID -> $WID3"
[ "${WTS3:-0}" -gt "${BEFORE_WTS:-0}" ] && ok "(a) planet timestamp grew: $BEFORE_WTS -> $WTS3" || bad "(a) planet timestamp did not grow: $BEFORE_WTS -> $WTS3"
echo "$VERIFY3" | grep -q 'signature_valid=true' && ok "(a) regenerated planet still verifies" || bad "(a) regenerated planet signature is invalid"
echo "$VERIFY3" | grep -q "root\[0\].endpoint\[0\]=$NEW_IP/9994" && ok "(a) planet now advertises the new endpoint $NEW_IP/9994" || bad "(a) planet endpoint is not $NEW_IP/9994"
echo "$VERIFY3" | grep -q "root\[0\].identity=$AFTER_ID" && ok "(a) planet root identity still the node identity" || bad "(a) planet root identity does not match the node identity"
[ "$BEFORE_MOON" = "$AFTER_MOON" ] && ok "moon ID (and its signing key) survived: $AFTER_MOON" || bad "moon changed: $BEFORE_MOON -> $AFTER_MOON"

CODE_N3="$(curl -s -o "$TMP/net3.json" -w '%{http_code}' -H "X-ZT1-Auth: $TOK3" "http://127.0.0.1:$API_PORT/controller/network/$NWID")"
echo "  GET /controller/network/$NWID -> $CODE_N3"
head -c 200 "$TMP/net3.json"; echo
[ "$CODE_N3" = "200" ] && ok "(c) controller data intact: network $NWID still readable after REGENERATE_WORLD" || bad "(c) network $NWID disappeared after REGENERATE_WORLD ($CODE_N3)"
python3 - "$TMP/net3.json" "$NWID" <<'PY' && ok "(c) network id and config unchanged" || bad "(c) network config changed"
import json
import sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
sys.exit(0 if (cfg.get("id") == sys.argv[2] and cfg.get("name") == "w1-acceptance") else 1)
PY
CODE_P3="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$FILES_PORT/planet?token=$DOWNLOAD_TOKEN")"
[ "$CODE_P3" = "200" ] && ok "download service serves the regenerated planet" || bad "/planet after REGENERATE_WORLD -> $CODE_P3"

# ------------------------------- 8. REGENERATE_WORLD=1 must refuse to mint an identity
head1 "8. REGENERATE_WORLD=1 on an empty volume must fail instead of creating a new identity"
FRESH_VOL="zt-planet-verify-fresh"
docker rm -f "$NAME-fresh" >/dev/null 2>&1
docker volume rm "$FRESH_VOL" >/dev/null 2>&1
OUT8="$(docker run --rm --name "$NAME-fresh" -e PUBLIC_IPV4="$NEW_IP" -e REGENERATE_WORLD=1 -v "$FRESH_VOL:/var/lib/zerotier-one" "$IMAGE" 2>&1)"
RC8=$?
echo "$OUT8" | tail -4 | sed 's/^/  | /'
echo "  exit code = $RC8"
[ "$RC8" -ne 0 ] && ok "(d) REGENERATE_WORLD=1 without identity exits non-zero ($RC8)" || bad "(d) REGENERATE_WORLD=1 without identity exited 0"
echo "$OUT8" | grep -q 'REGENERATE_WORLD=1 needs the existing node identity' && ok "(d) it says why it refused" || bad "(d) refusal message missing"
LEFT8="$(docker run --rm --entrypoint sh -v "$FRESH_VOL:/var/lib/zerotier-one" "$IMAGE" -c 'ls -A /var/lib/zerotier-one | tr "\n" " "')"
echo "  volume contents after refusal: ${LEFT8:-<empty>}"
case "$LEFT8" in
*identity.secret*) bad "(d) an identity was created anyway" ;;
*) ok "(d) no identity was created" ;;
esac
docker volume rm "$FRESH_VOL" >/dev/null 2>&1

# --------------------------------------- 9. FORCE_REGENERATE=1 still does a full rebuild
head1 "9. FORCE_REGENERATE=1 regression: full rebuild, new identity"
docker rm -f "$NAME" >/dev/null
docker run -d --name "$NAME" \
	-e PUBLIC_IPV4="$NEW_IP" -e ZT_PORT=9994 -e DOWNLOAD_TOKEN="$DOWNLOAD_TOKEN" -e FORCE_REGENERATE=1 \
	-p "$FILES_PORT:3000" -p "$API_PORT:9993" -p "$API_PORT:9993/udp" \
	-v "$VOL:/var/lib/zerotier-one" \
	"$IMAGE" >/dev/null
rm -f "$TMP/token"
wait_api && ok "container came up with FORCE_REGENERATE=1" || { bad "container did not come up with FORCE_REGENERATE=1"; docker logs --tail 40 "$NAME"; }
docker logs "$NAME" 2>&1 | grep -a 'entrypoint:' | head -8 | sed 's/^/  | /'
TOK4="$(cat "$TMP/token")"
FORCE_ID="$(docker exec "$NAME" cat /var/lib/zerotier-one/identity.public)"
FORCE_WTS="$(curl -fsS -H "X-ZT1-Auth: $TOK4" "http://127.0.0.1:$API_PORT/status" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("planetWorldTimestamp", 0))')"
FORCE_VERIFY="$(docker exec "$NAME" mkworld verify /var/lib/zerotier-one/planet 2>&1)"
echo "  identity: ${AFTER_ID%%:*} -> ${FORCE_ID%%:*}"
echo "  world ts: $WTS3 -> $FORCE_WTS"
echo "$FORCE_VERIFY" | grep -E 'signature_valid|root\[0\].identity|root\[0\].endpoint' | sed 's/^/  | /'
[ "$FORCE_ID" != "$AFTER_ID" ] && ok "FORCE_REGENERATE=1 minted a new identity ($(echo "$FORCE_ID" | cut -d: -f1))" || bad "FORCE_REGENERATE=1 did not change the identity"
[ "${FORCE_WTS:-0}" -gt "${WTS3:-0}" ] && ok "FORCE_REGENERATE=1 rebuilt the world (ts $WTS3 -> $FORCE_WTS)" || bad "FORCE_REGENERATE=1 did not rebuild the world"
echo "$FORCE_VERIFY" | grep -q "root\[0\].identity=$FORCE_ID" && ok "rebuilt planet is self-consistent with the new identity" || bad "rebuilt planet does not match the new identity"
docker exec "$NAME" zerotier-cli info 2>&1 | grep -q '200 info' && ok "node is ONLINE after FORCE_REGENERATE=1" || bad "node not ONLINE after FORCE_REGENERATE=1"

head1 "result"
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
