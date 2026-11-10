#!/bin/bash
# Build ccr.ccs.tencentyun.com/vnimy/zerotier-planet:<tag>.
#
# The ZeroTier source is exported straight out of the local clone at the given
# tag (git archive, read-only), so the image is built from exactly 1.16.2 and no
# network access to GitHub is needed.
set -euo pipefail
cd "$(dirname "$0")"

ZT_TAG="${ZT_TAG:-1.16.2}"
ZTSRC="${ZTSRC:-../../ZeroTierOne}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"
IMAGE="${IMAGE:-ccr.ccs.tencentyun.com/vnimy/zerotier-planet:${ZT_TAG}}"
TARBALL=ZeroTierOne.tar.gz

[ -d "$ZTSRC/.git" ] || { echo "no git checkout at $ZTSRC (set ZTSRC=...)" >&2; exit 1; }

echo "== source: $(git -C "$ZTSRC" rev-parse --short "${ZT_TAG}^{commit}") ($(git -C "$ZTSRC" rev-parse "${ZT_TAG}^{commit}"))"
git -C "$ZTSRC" show "${ZT_TAG}:version.h" | grep -E '#define ZEROTIER_ONE_VERSION_(MAJOR|MINOR|REVISION) ' || true

git -C "$ZTSRC" archive --format=tar.gz --prefix=ZeroTierOne/ "${ZT_TAG}" > "$TARBALL"
echo "== context tarball: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

set -x
docker build --build-arg BASE="$BASE_IMAGE" -t "$IMAGE" .
