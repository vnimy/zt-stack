# Vendored `mkworld` — planet (world) generator

`mkworld` turns "root identity + stable endpoints" into a signed `planet` file
that ZeroTier members use as their world definition. It is built here as a
standalone C++11 program, so the image does not need the per-version ZeroTier
build tree the way upstream's `attic/world` does.

## Provenance

| item | value |
| --- | --- |
| upstream generator | `zerotier/ZeroTierOne`, `attic/world/mkworld.cpp` |
| generator blob | `6b9bbe8d0d28a2a13a7eab15f8458f761cdd4004` |
| branch/commit it was taken from | `actions` @ `d2c745c285150cd211667fd8691369747d82095e` |
| supporting tree (node/osdep/include/ext) | commit `5e8e93518` ("world!", 2019-08-30) |
| upstream build recipe | `attic/world/build.sh` (kept verbatim as `UPSTREAM-build.sh.txt`) |

Why two commits: the `attic/world/mkworld.cpp` blob at `d2c745c` is
**byte-identical** (same SHA-1) to the one in mainline commit `5e8e93518`, which
is the commit that introduced it — verified locally with
`git rev-parse 5e8e93518:attic/world/mkworld.cpp` →
`6b9bbe8d0d28a2a13a7eab15f8458f761cdd4004`.

The generator itself therefore *is* the `actions`-branch file. Its dependency
closure, however, has to come from a tree that still has `node/C25519.hpp`
(Ed25519): `mkworld` signs the world with C25519, while ZeroTier **1.16.2** has
moved to `node/ECC.hpp` (P-384) and no longer ships `C25519.*` at all.
`5e8e93518` is the mainline commit that introduced this exact generator, so its
tree is the self-consistent source for the closure, and the build is reproducible
offline from the local clone (no GitHub access at build time).

## What was vendored (trimmed closure)

Everything is needed for `attic/world/build.sh` to link; nothing else was copied
(no `node/Node.cpp`, no `service/`, no `nonfree/`).

```
mkworld.cpp              patched generator (see below)
mkworld-upstream.cpp     the unmodified upstream file, kept for diffing
UPSTREAM-build.sh.txt    upstream recipe
UPSTREAM-README.md       upstream README
build.sh                 build recipe used by the Dockerfile
node/C25519.cpp  node/Salsa20.cpp  node/SHA512.cpp
node/Identity.cpp  node/Utils.cpp  node/InetAddress.cpp   (upstream builds exactly these six)
node/*.hpp               41 headers, the transitive header closure of the six sources
osdep/OSUtils.cpp  osdep/OSUtils.hpp
include/ZeroTierOne.h    pulled in by node/Constants.hpp
ext/json/json.hpp        pulled in by osdep/OSUtils.hpp
```

Licence: GPLv3, as in the upstream file headers (`mkworld.cpp`, `node/`,
`osdep/`). `include/ZeroTierOne.h` and `ext/json/json.hpp` keep their own
upstream headers (BSL 1.1 / MIT respectively).

## Patch on top of upstream

`mkworld-upstream.cpp` hard-codes the official ZeroTier planet (5 fixed roots
with fixed IPs) and takes no arguments, which is useless for a self-hosted
planet. `mkworld.cpp` changes only that block plus argument handling:

* `mkworld build <world.conf> <out.bin>` — reads a line-oriented config instead
  of the hard-coded roots.
* `mkworld verify <planet.bin>` — deserializes a planet file, re-checks its
  Ed25519 signature and prints id / timestamp / signing key / roots. Needed
  because `zerotier-idtool` has no command that dumps a world.
* Key handling is untouched: `previous.c25519` and `current.c25519` are read
  from the working directory and created there when absent, so the entrypoint
  runs it with the data volume as cwd and the world signing key survives restarts.

`world.conf`:

```
world_id=149604618      # optional, default ZT_WORLD_ID_EARTH
ts=1794274921601        # optional, default "now" in ms
root=<identity.public>  # starts a new root
endpoint=1.2.3.4/9994   # stable endpoint of the current root; IPv6 unbracketed
```

## Build

```sh
./build.sh            # g++ -std=c++11 -O2 -I. -o mkworld ... -lm
./mkworld verify ../planet
```

## Verification performed

Built with g++ 13 (Ubuntu 24.04). Round trip on a generated world:

```
type=planet
world_id=149604618
timestamp=1794274921601
signature_valid=true
signing_key=c984af1e...e33edb85d9
roots=1
root[0].identity=3a46f1bf30:0:76e66fab...
root[0].endpoint[0]=1.2.3.4/9994
root[0].endpoint[1]=2001:db8::1/9994
```

Single warning in the build: `-Wmaybe-uninitialized` on
`node/World.hpp:213` inside `World::deserialize` (upstream code, harmless).
