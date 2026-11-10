#!/bin/bash
# Entrypoint for the ZeroTier planet (root) node image.
#
# Lifecycle, in order of precedence:
#
#   volume ready, no switch      -> reuse everything (identity, planet, moons)
#   FORCE_REGENERATE=1           -> FULL rebuild: NEW node identity + new world signing
#                                   key + new planet + new moon. Every self-hosted
#                                   network ID dies with the old identity (the network ID
#                                   is prefixed with the controller's node address) and
#                                   members have to join again. The planet must be
#                                   redistributed because the world signing key changed.
#   REGENERATE_WORLD=1           -> WORLD-ONLY rebuild: keep identity.secret/public,
#                                   authtoken.secret, controller.d, networks.d, the world
#                                   signing key (previous.c25519/current.c25519) and the
#                                   moon signing key inside moon.json; rewrite only
#                                   moon.json endpoints, moons.d and planet with the new
#                                   PUBLIC_IPV4/PUBLIC_IPV6/ZT_PORT and a new timestamp.
#                                   Network IDs, members and ZTNet state stay valid; only
#                                   the planet file has to be redistributed.
#   volume empty/incomplete       -> first initialisation (creates a NEW identity)
#
# FORCE_REGENERATE wins when both switches are set (it is the more destructive intent);
# the entrypoint says so in the log.
#
# Then: planet file service in the background, zerotier-one in the foreground.
set -euo pipefail

ZT_HOME=/var/lib/zerotier-one
ZT_API_PORT=9993
PUBLIC_IPV4="${PUBLIC_IPV4:-}"
PUBLIC_IPV6="${PUBLIC_IPV6:-}"
ZT_PORT="${ZT_PORT:-9994}"
FILES_PORT="${FILES_PORT:-3000}"
DOWNLOAD_TOKEN="${DOWNLOAD_TOKEN:-}"
ENABLE_CONTROLLER="${ENABLE_CONTROLLER:-1}"
ALLOW_MANAGEMENT_FROM="${ALLOW_MANAGEMENT_FROM:-172.16.0.0/12}"
FORCE_REGENERATE="${FORCE_REGENERATE:-0}"
REGENERATE_WORLD="${REGENERATE_WORLD:-0}"

log() { printf '%s entrypoint: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

case "$ZT_PORT" in ''|*[!0-9]*) die "ZT_PORT='$ZT_PORT' is not a port number";; esac
case "$FILES_PORT" in ''|*[!0-9]*) die "FILES_PORT='$FILES_PORT' is not a port number";; esac

[ -n "$PUBLIC_IPV4" ] || die "PUBLIC_IPV4 is required: it becomes the stable endpoint of this planet"
[ -n "$ALLOW_MANAGEMENT_FROM" ] || die "ALLOW_MANAGEMENT_FROM must not be empty"
if [ "$ENABLE_CONTROLLER" != "1" ]; then
	log "WARNING: ENABLE_CONTROLLER=$ENABLE_CONTROLLER ignored: this build has the embedded controller compiled in (ZT_NONFREE=1) and ZeroTier has no runtime switch to turn it off; /controller/* stays reachable for callers that pass allowManagementFrom + authtoken"
fi

mkdir -p "$ZT_HOME/moons.d" "$ZT_HOME/controller.d"

state_ready() {
	[ -s "$ZT_HOME/identity.secret" ] &&
		[ -s "$ZT_HOME/identity.public" ] &&
		[ -s "$ZT_HOME/authtoken.secret" ] &&
		[ -s "$ZT_HOME/local.conf" ] &&
		[ -s "$ZT_HOME/planet" ]
}

write_local_conf() {
	local amf_json
	amf_json=$(printf '%s' "$ALLOW_MANAGEMENT_FROM" | awk -F, '{out=""; for (i=1;i<=NF;i++) {gsub(/^[ \t]+|[ \t]+$/,"",$i); if ($i!="") {out = out (out=="" ? "" : ", ") "\"" $i "\""}}; print out}')
	[ -n "$amf_json" ] || die "ALLOW_MANAGEMENT_FROM parsed to an empty list"
	cat >"$ZT_HOME/local.conf" <<EOF
{
	"physicalPath": "$ZT_HOME",
	"settings": {
		"primaryPort": $ZT_API_PORT,
		"secondaryPort": 0,
		"allowManagementFrom": [$amf_json],
		"allowTcpFallbackRelay": false,
		"portMappingEnabled": false,
		"softwareUpdate": "disable"
	}
}
EOF
	chmod 644 "$ZT_HOME/local.conf"
}

# identity.secret/public (+ authtoken.secret if there is none yet)
generate_identity() {
	cd "$ZT_HOME"

	log "generating node identity"
	rm -f identity.secret identity.public
	zerotier-idtool generate identity.secret identity.public >/dev/null
	chmod 600 identity.secret
	chmod 644 identity.public

	if [ -s authtoken.secret ]; then
		log "keeping existing authtoken.secret"
	else
		log "generating authtoken.secret"
		head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' >authtoken.secret
		chmod 600 authtoken.secret
	fi
}

# moon.json -> gensigned moons.d/<moonid>.moon for the current PUBLIC_IPV4/IPv6:ZT_PORT.
# $1 = "new": discard the old moon definition (full rebuild, identity just changed).
#      "keep": reuse moon.json so the moon ID and its signing key survive.
generate_moon() {
	local mode="${1:-keep}"
	cd "$ZT_HOME"

	if [ "$mode" = "new" ]; then
		log "generating a new moon definition"
		rm -f ./*.moon moon.json
		zerotier-idtool initmoon identity.public >moon.json
	elif [ -s moon.json ]; then
		log "reusing existing moon definition (moon ID and signing key preserved)"
	else
		log "WARNING: moon.json is missing, creating a new one: the MOON ID CHANGES, clients that orbit the old moon must orbit the new one"
		rm -f ./*.moon
		zerotier-idtool initmoon identity.public >moon.json
	fi

	python3 - "$ZT_HOME/moon.json" "$ZT_HOME/identity.public" "$PUBLIC_IPV4" "$PUBLIC_IPV6" "$ZT_PORT" <<'PY'
import json
import sys

path, identity_path, ip4, ip6, port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
endpoints = ["%s/%s" % (ip4, port)]
if ip6:
    endpoints.append("%s/%s" % (ip6, port))
with open(path, "r") as fp:
    moon = json.load(fp)
with open(identity_path, "r") as fp:
    identity = fp.read().strip()
moon_identity = moon["roots"][0]["identity"]
if moon_identity != identity:
    sys.exit("moon.json belongs to %s, not to the current identity %s" % (moon_identity[:10], identity[:10]))
moon["roots"][0]["stableEndpoints"] = endpoints
with open(path, "w") as fp:
    json.dump(moon, fp, indent=2, sort_keys=True)
    fp.write("\n")
print("moon endpoints: %s" % ", ".join(endpoints))
PY
	zerotier-idtool genmoon moon.json >/dev/null
	mkdir -p moons.d
	rm -f moons.d/*.moon
	mv -f ./*.moon moons.d/
	chmod 644 moons.d/*.moon
	log "moon written: $(cd moons.d && ls -1 | tr '\n' ' ')"
}

# planet (world) for the current identity + endpoints, signed by previous/current.c25519
generate_planet() {
	cd "$ZT_HOME"
	log "generating planet world (root endpoint $PUBLIC_IPV4/$ZT_PORT)"
	{
		printf 'root=%s\n' "$(cat identity.public)"
		printf 'endpoint=%s/%s\n' "$PUBLIC_IPV4" "$ZT_PORT"
		if [ -n "$PUBLIC_IPV6" ]; then
			printf 'endpoint=%s/%s\n' "$PUBLIC_IPV6" "$ZT_PORT"
		fi
	} >world.conf
	mkworld build world.conf planet >&2
	rm -f world.conf world.bin
	chmod 644 planet
}

# Full rebuild: identity, authtoken, local.conf, moon and planet.
generate_all() {
	cd "$ZT_HOME"
	generate_identity
	log "writing local.conf (primaryPort=$ZT_API_PORT, allowManagementFrom=$ALLOW_MANAGEMENT_FROM)"
	write_local_conf
	generate_moon new
	generate_planet
}

# World-only rebuild: keeps identity, authtoken, controller/networks data and both
# signing keys; only the two things that embed the endpoint list are rewritten.
regenerate_world_only() {
	cd "$ZT_HOME"

	[ -s identity.secret ] && [ -s identity.public ] ||
		die "REGENERATE_WORLD=1 needs the existing node identity (identity.secret/identity.public). Refusing to create a new one: every self-hosted network ID is derived from the controller address, so a new identity would invalidate all networks and members. Use FORCE_REGENERATE=1 for a full rebuild with a new identity."
	[ -s previous.c25519 ] && [ -s current.c25519 ] ||
		die "REGENERATE_WORLD=1 needs the existing world signing key (previous.c25519/current.c25519). A new key cannot overwrite the planet clients already trust; use FORCE_REGENERATE=1 and redistribute the planet to every member."

	log "REGENERATE_WORLD=1: keeping identity $(cut -d: -f1 <identity.public), authtoken, controller data and the world signing key"
	[ -s local.conf ] || { log "local.conf is missing, writing it"; write_local_conf; }
	generate_moon keep
	generate_planet
}

if [ "$FORCE_REGENERATE" = "1" ]; then
	if [ "$REGENERATE_WORLD" = "1" ]; then
		log "NOTE: FORCE_REGENERATE=1 and REGENERATE_WORLD=1 are mutually exclusive; FORCE_REGENERATE wins, so the node identity WILL change"
	fi
	log "FORCE_REGENERATE=1: full rebuild, discarding identity, authtoken, planet, moons, local.conf and the world signing key"
	cd "$ZT_HOME"
	rm -f identity.secret identity.public planet moon.json world.conf world.bin previous.c25519 current.c25519
	rm -f moons.d/*.moon
	generate_all
elif [ "$REGENERATE_WORLD" = "1" ]; then
	regenerate_world_only
elif state_ready; then
	log "existing state found, reusing identity and planet (set REGENERATE_WORLD=1 to move to a new IP, FORCE_REGENERATE=1 for a full rebuild)"
else
	log "empty or incomplete data volume, initialising (this creates a NEW node identity)"
	generate_all
fi

log "planet: $(mkworld verify "$ZT_HOME/planet" 2>&1 | tr '\n' ' ')"
log "identity: $(cat "$ZT_HOME/identity.public")"
if [ -n "$DOWNLOAD_TOKEN" ]; then
	log "planet/moon download service on :$FILES_PORT (token required)"
else
	log "planet/moon download service on :$FILES_PORT (no token)"
fi

python3 /usr/local/bin/planet-files.py &
FILES_PID=$!
trap 'kill "$FILES_PID" 2>/dev/null || true' EXIT TERM INT

for _ in $(seq 1 50); do
	if python3 -c 'import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(("127.0.0.1", int(sys.argv[1]))) == 0 else 1)' "$FILES_PORT" 2>/dev/null; then
		log "download service is up"
		break
	fi
	sleep 0.1
done

log "starting zerotier-one (api $ZT_API_PORT, peer udp $ZT_API_PORT, controller embedded)"
exec zerotier-one
