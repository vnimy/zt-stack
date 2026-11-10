# planet-node — self-hosted ZeroTier planet (root) + embedded controller

One container = the root node of your own ZeroTier "world" **and** the network
controller, plus a small HTTP service that hands out `planet` / moon files.
Image: `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`.

```
         ┌──────────────────────── planet-node container ───────────────────────┐
         │ zerotier-one 1.16.2 (ZT_NONFREE=1)                                   │
         │   • listens 9993/udp  → peer transport, this node is the world root   │
         │   • listens 9993/tcp  → management API + /controller/* (embedded)     │
         │   • /var/lib/zerotier-one = identity, authtoken, planet, moons.d,     │
         │                             controller.d                              │
         │ planet-files.py : 3000/tcp → /planet /moons /moon/<f> /healthz /      │
         └──────────────────────────────────────────────────────────────────────┘
```

## Hardcoded contract (compose/clients rely on it)

* image tag `ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2`
* inside the container `zerotier-one` always listens on **9993** (tcp+udp); the
  port mapping to the outside is the compose file's business
* data volume `/var/lib/zerotier-one`
* `planet` advertises the root endpoint `PUBLIC_IPV4:ZT_PORT` (and the same for
  `PUBLIC_IPV6` when given) — "provide the server IP at deploy time" happens here

| env | default | meaning |
| --- | --- | --- |
| `PUBLIC_IPV4` | **required** | public IPv4 of this node; becomes the planet's stable endpoint |
| `PUBLIC_IPV6` | empty | optional IPv6, same handling |
| `ZT_PORT` | `9994` | advertised (public) port written into planet/moon; compose maps it to 9993 |
| `FILES_PORT` | `3000` | port of the planet/moon download service |
| `DOWNLOAD_TOKEN` | empty | token for the download service; **empty disables authentication** |
| `ENABLE_CONTROLLER` | `1` | see limitation below |
| `ALLOW_MANAGEMENT_FROM` | `172.16.0.0/12` | CIDRs allowed to reach the API besides loopback (comma separated) |
| `FORCE_REGENERATE` | `0` | `1` = full rebuild even though the volume is populated: **new node identity**, new world signing key, new planet, new moon, new `local.conf`. Every self-hosted network ID dies with the identity |
| `REGENERATE_WORLD` | `0` | `1` = rebuild **planet + moons only** for a new endpoint (new IP / new port): keeps identity, authtoken, `controller.d`, `networks.d` and both signing keys, so network IDs and memberships survive. Refuses to run (exit 1) if the identity or the world signing key is missing |

The management API is always proxied by compose (never exposed publicly in
cleartext); the token lives in `/var/lib/zerotier-one/authtoken.secret`.

## Files

| file | role |
| --- | --- |
| `Dockerfile` | three stages: ZeroTier 1.16.2 build, mkworld build, runtime |
| `build.sh` | exports `ZeroTierOne`@`1.16.2` with `git archive`, then `docker build` |
| `entrypoint.sh` | idempotent first-start state generation, then foreground `zerotier-one` |
| `planet-files.py` | download service (`/planet`, `/moons`, `/moon/<f>`, `/healthz`, `/`) |
| `verify.sh` | single-container acceptance run (all six checks, PASS/FAIL lines) |
| `mkworld/` | vendored planet generator, see `mkworld/README.md` |

## Build

```sh
./build.sh            # = git archive 1.16.2 → docker build -t ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2 .
```

`build.sh` writes the 12 MB context tarball `ZeroTierOne.tar.gz` next to the
Dockerfile (it is a build artifact, deleted after a build is fine).

No network beyond the Ubuntu archive is needed: `mkworld` is vendored and the
ZeroTier source is exported from the local clone at the tag. Requirements: a local
ZeroTierOne git clone (override with `ZTSRC=/path`), `docker`.

`ZT_SSO_SUPPORTED=0` is passed to `make`: SSO/OIDC is the only consumer of
`rustybits` (Rust + a git dependency), and a planet/controller node never runs the
client-side OIDC login. Skipping it keeps a Rust toolchain and `libssl` out of the
image. `ZT_NONFREE=1` is what puts the embedded controller in.

## Run (single container, as used by verify.sh)

```sh
docker volume create zt-planet
docker run -d --name zt-planet \
  -e PUBLIC_IPV4=203.0.113.10 -e ZT_PORT=9994 -e DOWNLOAD_TOKEN=s3cret \
  -p 9994:9993 -p 9994:9993/udp -p 3000:3000 \
  -v zt-planet:/var/lib/zerotier-one \
  ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2
```

First start creates, inside the volume:

```
identity.secret / identity.public   node identity (= planet root identity)
authtoken.secret                    management API token
local.conf                          primaryPort=9993, allowManagementFrom, controller on
moon.json + moons.d/<moonid>.moon   moon definition signed by this identity
world.conf (transient) + planet     the world file, signed by previous/current.c25519
previous.c25519 / current.c25519    world signing key, kept so later worlds stay trusted
```

A populated volume is reused as-is on restart (same identity, same
`planetWorldId`/`planetWorldTimestamp`); `FORCE_REGENERATE=1` rewrites all of it.

## Acceptance

`./verify.sh` builds nothing, it runs the image and checks, with PASS/FAIL lines:
identity/version, planet on disk (signature + root identity vs node identity +
advertised endpoint), `/status` `planetWorldId`/`planetWorldTimestamp`,
controller network create+read, download service (token ok / Bearer / wrong token
401 / `/healthz` / index / `/moons`), and idempotence over `docker restart`.

## Moving to a new IP / new port / new machine

Two switches, two very different outcomes. The node identity is the anchor: the
embedded controller's node address is the first 10 hex of every network ID it
creates, so **losing the identity loses every network ID**.

| | `REGENERATE_WORLD=1` | `FORCE_REGENERATE=1` |
| --- | --- | --- |
| touches | `planet`, `moons.d` (+ `local.conf` only if missing) | everything: identity, world key, planet, moons, `local.conf` |
| node identity | **kept** | replaced |
| world signing key (`previous/current.c25519`) | **kept** | replaced |
| `authtoken.secret` | kept | kept (only rewritten if absent) |
| controller data (`controller.d`) / `networks.d` | kept | kept on disk, but orphaned: old network IDs can never be joined again |
| network IDs | **unchanged** | all new, old ones dead |
| members | **stay joined**, nothing to redo on ZTNet | must join the new networks |
| ZTNet | keeps working, token unchanged, no restart needed | must be re-pointed and networks re-created |
| planet | must be redistributed, clients take it as a signed update | must be **replaced**, not updated (new signing key, old clients cannot verify it) |
| moon ID | kept | new |

### A. Same identity, new address (recommended)

```sh
docker stop zt-planet && docker rm zt-planet
docker run -d --name zt-planet \
  -e PUBLIC_IPV4=<NEW_IP> -e REGENERATE_WORLD=1 -e ZT_PORT=9994 \
  -p 9994:9993 -p 9994:9993/udp -p 3000:3000 \
  -v zt-planet:/var/lib/zerotier-one \
  ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2
```

The entrypoint keeps `identity.secret/public`, `authtoken.secret`,
`controller.d`, `networks.d`, `previous.c25519`/`current.c25519` and the moon
signing key inside `moon.json`; it rewrites the endpoint list in `moon.json`,
regenerates `moons.d`, and re-signs `planet` with a **new timestamp**. Because the
world id is unchanged, the timestamp is newer and the signature is by the key
clients already trust (`World::shouldBeReplacedBy`), the new `planet` is a valid
world update — but you still have to hand it out: the planet is not pushed from
the root. Members whose client still holds the old planet will keep looking for the
old endpoint, so **republish `/planet`** (and the moon, if you use one) and have
clients replace it before expecting them to reach the node.

If the identity or the world signing key is missing, this switch **refuses to
start** (exit 1, message "REGENERATE_WORLD=1 needs the existing node identity...")
rather than quietly minting a new identity — that is exactly the accident this
switch exists to prevent. It also never touches `controller.d`.

Changing `ZT_PORT` or adding/changing `PUBLIC_IPV6` is the same operation: any
change to the advertised endpoint needs a new signed world.

### B. New node identity (full rebuild)

`FORCE_REGENERATE=1` deletes `identity.secret/public`, `previous.c25519`,
`current.c25519`, `planet`, `moon.json`, `moons.d/*.moon` and recreates all of
them. Consequences: the controller address changes, so **every network ID changes**
(the old `controller.d` files stay on disk but are unreachable), every member has to
join the new network IDs, ZTNet has to be re-pointed at the new controller address
and its networks have to be recreated, and the new planet cannot be delivered as an
update — clients must **remove their old planet file and drop the new one in**, then
restart. Use it for a lost/compromised volume or a real re-deployment, not for a
new IP.

If both switches are set, `FORCE_REGENERATE` wins and the entrypoint says so in the
log ("mutually exclusive; FORCE_REGENERATE wins, so the node identity WILL change").

## Controller API on 1.16.2 (read this before writing the admin UI / W2 wiring)

The routes in this build (`nonfree/controller/EmbeddedNetworkController.cpp`) are:

| method | path | meaning |
| --- | --- | --- |
| POST/PUT | `/controller/network` | create; **the controller picks the 16-hex network id itself** and returns it in the response body's `id` |
| GET | `/controller/network` | list all networks |
| GET / POST / DELETE | `/controller/network/<16 hex>` | read / update config / delete |
| GET / POST / DELETE | `/controller/network/<16 hex>/member/<10 hex>` | member list, update, delete |
| POST/PUT | `/controller/network/<10 hex>______` | legacy create (the 10 hex must be this node's address) |

`POST /controller/network/<id>` with an id you invented is **not** a create path —
`networkPath` only accepts 16 hex characters and only for updates, so that call
answers 404. All calls need `X-ZT1-Auth: <authtoken>` (or `?auth=`) and a source
address inside `ALLOW_MANAGEMENT_FROM` (loopback always allowed).

## Evidence from the acceptance run

```
image                ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2   180 MB
full build           288 s (apt + ZeroTier 1.16.2 + mkworld + runtime), 0 warnings from ZT's build
rebuild (cached)     15 s
./verify.sh          23 passed, 0 failed
sockets inside       0.0.0.0:9993/tcp LISTEN, [::]:9993/tcp LISTEN, 172.17.0.2:9993/udp, 0.0.0.0:3000/tcp
```

`zerotier-one`'s own dependencies inside the image are only `libstdc++`,
`libm`, `libgcc_s`, `libc` (no `libssl`, because SSO is compiled out).

## Notes and known limitations

* **`ENABLE_CONTROLLER=0` is a no-op.** `ZT_NONFREE=1` compiles
  `EmbeddedNetworkController` into `zerotier-one` unconditionally
  (`service/OneService.cpp`, `ZT_NONFREE_CONTROLLER`) and ZeroTier 1.16.2 exposes
  no runtime switch; the entrypoint logs a warning instead of pretending
  otherwise. Access control is the API token plus `ALLOW_MANAGEMENT_FROM`.
* **`zerotier-idtool` cannot print a planet.** It only knows
  `generate/validate/getpublic/sign/verify/initmoon/genmoon`, so reading the planet
  back out of the volume is done with the vendored `mkworld verify`
  (deserialize + Ed25519 signature check). Same evidence, different tool.
* The download service speaks plain HTTP; TLS terminates in front of it (Caddy
  sidecar, next task) — it only ever serves two kinds of file.
* The world timestamp is `now` (ms) at generation time and the world id stays
  `ZT_WORLD_ID_EARTH` (149604618); both are what `/status` reports as
  `planetWorldId`/`planetWorldTimestamp`.
