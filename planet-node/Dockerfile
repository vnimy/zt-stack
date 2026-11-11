# Self-hosted ZeroTier planet (root) node with the embedded network controller.
#
# Build with ./build.sh, which puts the tagged ZeroTier source into the context
# as ZeroTierOne.tar.gz. Everything else (mkworld) is vendored next to this file,
# so the build needs no git clone and no access to GitHub.
#
#   docker build -t ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2 .
ARG BASE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Stage A: zerotier-one 1.16.2 with ZT_NONFREE=1 (planet root + controller).
#
# ZT_SSO_SUPPORTED is forced to 0: SSO/OIDC lives in rustybits, a Rust staticlib
# with a git dependency, and a planet/controller node never performs the
# client-side OIDC login it implements. Dropping it keeps the build free of a
# Rust toolchain and drops the libssl runtime dependency.
# ---------------------------------------------------------------------------
FROM ${BASE} AS zt-build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ADD ZeroTierOne.tar.gz /src/
WORKDIR /src/ZeroTierOne
RUN grep -q '#define ZEROTIER_ONE_VERSION_REVISION 2' version.h \
 && grep -q '#define ZEROTIER_ONE_VERSION_MINOR 16' version.h
RUN make -j"$(nproc)" ZT_NONFREE=1 ZT_SSO_SUPPORTED=0 one \
 && ./zerotier-idtool 2>&1 | head -1 \
 && ldd ./zerotier-one | grep -c 'not found' | grep -q '^0$'

# ---------------------------------------------------------------------------
# Stage B: vendored mkworld (planet generator, pure C++11, no ZeroTier build tree)
# ---------------------------------------------------------------------------
FROM ${BASE} AS mkworld-build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
COPY mkworld/ /mkworld/
RUN /mkworld/build.sh && /mkworld/mkworld 2>&1 | head -2

# ---------------------------------------------------------------------------
# Stage C: runtime
# ---------------------------------------------------------------------------
FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zt-build /src/ZeroTierOne/zerotier-one /usr/sbin/zerotier-one
COPY --from=mkworld-build /mkworld/mkworld /usr/local/bin/mkworld
COPY planet-files.py /usr/local/bin/planet-files.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/planet-files.py /usr/local/bin/mkworld \
 && chmod 755 /usr/sbin/zerotier-one \
 && ln -sf zerotier-one /usr/sbin/zerotier-cli \
 && ln -sf zerotier-one /usr/sbin/zerotier-idtool

# Contract with the compose files (see zerotier-planet/README): these names and
# defaults are fixed, the container listens on 9993 inside and compose maps it.
ENV PUBLIC_IPV4="" \
    PUBLIC_IPV6="" \
    ZT_PORT="9994" \
    FILES_PORT="3000" \
    DOWNLOAD_TOKEN="" \
    ENABLE_CONTROLLER="1" \
    ALLOW_MANAGEMENT_FROM="172.16.0.0/12" \
    FORCE_REGENERATE="0" \
    REGENERATE_WORLD="0"

VOLUME ["/var/lib/zerotier-one"]
# 9993/tcp = management API + controller, 9993/udp = peer transport, 3000/tcp = downloads
EXPOSE 9993/tcp 9993/udp 3000/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
	CMD python3 -c "import os,urllib.request;urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('FILES_PORT','3000')+'/healthz',timeout=3).read()" || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
