#!/bin/bash
# Entrypoint for the containerised ZeroTier client.
#
# Contract (all optional except ONE of PLANET_URL / an existing planet):
#
#   PLANET_URL      planet download URL, e.g. https://zt.vnimy.com/planet
#   PLANET_TOKEN    optional bearer token for that URL
#   PLANET_SHA256   optional expected sha256 of the planet (fails the start if it differs)
#   PLANET_UPDATE   1 (default) = download on every start, 0 = only when missing/unusable
#   NETWORK_ID      space or comma separated network IDs to join automatically
#   STATUS_INTERVAL seconds between status heartbeats (default 60)
#
# Lifecycle:
#   1. download + validate the planet (size 178..65536, first byte 0x01, optional sha256),
#      keep the previous one as planet.bak, replace it atomically
#   2. start zerotier-one, wait for its local API
#   3. join every network in NETWORK_ID (authorisation still happens on the controller:
#      the member shows up as ACCESS_DENIED until the panel authorises it)
#   4. log state changes, keep the container alive with zerotier-one
set -uo pipefail

ZT_HOME="${ZT_HOME:-/var/lib/zerotier-one}"
PLANET_URL="${PLANET_URL:-}"
PLANET_TOKEN="${PLANET_TOKEN:-}"
PLANET_SHA256="${PLANET_SHA256:-}"
PLANET_UPDATE="${PLANET_UPDATE:-1}"
NETWORK_ID="${NETWORK_ID:-}"
STATUS_INTERVAL="${STATUS_INTERVAL:-60}"

PLANET_MIN_BYTES=178
PLANET_MAX_BYTES=65536

log() { printf '%s client: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# ---------------------------------------------------------------- planet ----

planet_ok() { # $1 = path; quiet, for decisions
	local file="$1" size first
	[ -f "$file" ] || return 1
	size="$(wc -c <"$file" | tr -d ' ')"
	[ "$size" -ge "$PLANET_MIN_BYTES" ] 2>/dev/null || return 1
	[ "$size" -le "$PLANET_MAX_BYTES" ] 2>/dev/null || return 1
	first="$(od -An -tu1 -N1 "$file" | tr -d ' ')"
	[ "$first" = "1" ] || return 1
	return 0
}

install_planet() { # $1 = downloaded file, $2 = label for logs
	local tmp="$1" size sha
	size="$(wc -c <"$tmp" | tr -d ' ')"
	if ! planet_ok "$tmp"; then
		log "rejected planet from $2: size=$size, magic=$(od -An -tu1 -N1 "$tmp" | tr -d ' ')"
		return 1
	fi
	sha="$(sha256sum "$tmp" | awk '{print $1}')"
	if [ -n "$PLANET_SHA256" ] && [ "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" != "$(printf '%s' "$PLANET_SHA256" | tr 'A-F' 'a-f' | tr -d ' ')" ]; then
		log "rejected planet from $2: sha256 $sha != expected $PLANET_SHA256"
		return 1
	fi
	if [ -f "$ZT_HOME/planet" ]; then
		cp -f "$ZT_HOME/planet" "$ZT_HOME/planet.bak" || true
	fi
	mv -f "$tmp" "$ZT_HOME/planet"
	chmod 600 "$ZT_HOME/planet" 2>/dev/null || true
	log "planet installed from $2: ${size} bytes, sha256 $sha"
}

download_planet() {
	local tmp="$ZT_HOME/planet.tmp.$$" args
	args=(--fail --silent --show-error --location
		--retry 3 --retry-delay 2 --connect-timeout 10 --max-time 120
		--max-filesize "$PLANET_MAX_BYTES" -o "$tmp")
	[ -n "$PLANET_TOKEN" ] && args+=(-H "Authorization: Bearer $PLANET_TOKEN")
	log "downloading planet from $PLANET_URL"
	rm -f "$tmp"
	if ! curl "${args[@]}" "$PLANET_URL"; then
		rm -f "$tmp"
		log "download failed: $PLANET_URL"
		return 1
	fi
	install_planet "$tmp" "$PLANET_URL"
}

prepare_planet() {
	mkdir -p "$ZT_HOME"
	if [ -z "$PLANET_URL" ]; then
		if planet_ok "$ZT_HOME/planet"; then
			log "PLANET_URL not set, reusing existing planet"
		else
			log "PLANET_URL not set, using the built-in ZeroTier planet"
		fi
		return 0
	fi
	if [ "$PLANET_UPDATE" != "1" ] && planet_ok "$ZT_HOME/planet"; then
		log "PLANET_UPDATE=0 and a valid planet is present, not downloading"
		return 0
	fi
	if ! download_planet; then
		planet_ok "$ZT_HOME/planet" && {
			log "keeping the previous planet"
			return 0
		}
		die "no usable planet (download failed and none stored in $ZT_HOME)"
	fi
}

# ---------------------------------------------------------------- zerotier --

join_networks() {
	[ -n "$NETWORK_ID" ] || return 0
	local joined nw
	joined="$(zerotier-cli listnetworks 2>/dev/null | awk 'NR>1 {print $3}')"
	for nw in $(printf '%s' "$NETWORK_ID" | tr ',' ' '); do
		[ -n "$nw" ] || continue
		case " $joined " in
			*" $nw "*) log "already joined $nw" ;;
			*)
				if zerotier-cli join "$nw" >/dev/null 2>&1; then
					log "joined $nw"
				else
					log "join failed for $nw"
				fi
				;;
		esac
	done
}

network_state() {
	# Column positions shift when the network name is empty, so match the status
	# token instead of trusting a fixed field.
	zerotier-cli listnetworks 2>/dev/null | awk '
		NR > 1 {
			nw = $3; st = ""; ip = ""
			for (i = 1; i <= NF; i++)
				if ($i ~ /^(OK|ACCESS_DENIED|REQUESTING_CONFIGURATION|NOT_FOUND|PORT_ERROR|AUTHENTICATION_REQUIRED)$/) { st = $i; break }
			for (i = NF; i > 3; i--)
				if ($i ~ /^[0-9a-fA-F:.]+\/[0-9]+$/) { ip = $i; break }
			printf "%s=%s %s; ", nw, (st == "" ? "?" : st), (ip == "" ? "-" : ip)
		}'
}

supervise() {
	local last="" now i
	while kill -0 "$ZT_PID" 2>/dev/null; do
		sleep "$STATUS_INTERVAL" &
		wait $! 2>/dev/null || true
		kill -0 "$ZT_PID" 2>/dev/null || break
		now="$(network_state)"
		if [ "$now" != "$last" ]; then
			log "network state: ${now:-<none joined>}"
			last="$now"
		else
			log "still up: ${now:-<none joined>}"
		fi
	done
}

# ---------------------------------------------------------------- main ------

prepare_planet

log "starting zerotier-one (identity in $ZT_HOME)"
zerotier-one "$ZT_HOME" > >(sed -u 's/^/zerotier-one: /') 2>&1 &
ZT_PID=$!

trap 'log "stopping"; kill -TERM "$ZT_PID" 2>/dev/null; wait "$ZT_PID" 2>/dev/null; exit 0' TERM INT

for i in $(seq 1 60); do
	kill -0 "$ZT_PID" 2>/dev/null || die "zerotier-one exited during start-up"
	zerotier-cli info >/dev/null 2>&1 && break
	[ "$i" -eq 60 ] && die "zerotier-one did not answer on its local API within 60s"
	sleep 1
done

log "identity: $(zerotier-cli info 2>/dev/null | tr -s ' ')"
join_networks

if [ -n "$NETWORK_ID" ]; then
	for i in $(seq 1 15); do
		case "$(network_state)" in
			*"=OK"*) break ;;
		esac
		sleep 2
	done
	log "network state: $(network_state)"
fi

supervise
wait "$ZT_PID"
