#!/bin/bash
# Build (and optionally push) ccr.ccs.tencentyun.com/vnimy/zerotier-client:<tag>.
#
# The ZeroTier binaries come from the planet-node image, so the client always
# matches the server version. Nothing is downloaded from GitHub.
set -euo pipefail
cd "$(dirname "$0")"

ZT_TAG="${ZT_TAG:-1.16.2}"
ZT_IMAGE="${ZT_IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-planet:${ZT_TAG}}"
VERSION="${VERSION:-${ZT_TAG}}"
IMAGE="${IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-client:${VERSION}}"

echo "== binaries from: $ZT_IMAGE"
echo "== image:         $IMAGE"

set -x
docker build --build-arg ZT_IMAGE="$ZT_IMAGE" -t "$IMAGE" .
set +x

if [ "${1:-}" = "--push" ]; then
	echo "== pushing $IMAGE"
	docker push "$IMAGE"
fi

echo "== done: $IMAGE"
docker image inspect --format '{{.Id}} {{.Size}}' "$IMAGE"
