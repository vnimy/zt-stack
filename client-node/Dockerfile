# Containerised ZeroTier client for a self-hosted planet.
#
# The image is the stock 1.16.2 client binary taken from the planet image
# (same registry, same version), plus curl and this entrypoint. Nothing from
# the controller is included.
#
#   docker build -t zt-stack/zerotier-client:1.16.2 .
#   docker run -d --name zt-client \
#     --cap-add NET_ADMIN --device /dev/net/tun \
#     -e PLANET_URL=https://zt.vnimy.com/planet \
#     -e NETWORK_ID=e5c9db4519e04fa5 \
#     -v zt-client-data:/var/lib/zerotier-one \
#     zt-stack/zerotier-client:1.16.2

ARG ZT_IMAGE=ccr.ccs.tencentyun.com/vnimy/zerotier-planet:1.16.2
ARG BASE=ubuntu:24.04

# The client binary comes from the planet image so the version can never drift
# from the planet it talks to.
FROM ${ZT_IMAGE} AS zt

FROM ${BASE}
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 iproute2 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=zt /usr/sbin/zerotier-one /usr/sbin/zerotier-one
RUN chmod 755 /usr/sbin/zerotier-one \
 && ln -sf zerotier-one /usr/sbin/zerotier-cli \
 && ln -sf zerotier-one /usr/sbin/zerotier-idtool

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Contract with the compose file / docker run. Every value is optional: with no
# PLANET_URL and no stored planet the container behaves like a stock client
# (built-in ZeroTier roots).
ENV PLANET_URL="" \
    PLANET_TOKEN="" \
    PLANET_SHA256="" \
    PLANET_UPDATE="1" \
    NETWORK_ID="" \
    STATUS_INTERVAL="60" \
    ZT_HOME="/var/lib/zerotier-one"

VOLUME ["/var/lib/zerotier-one"]
# 9993/tcp = local management API, 9993/udp = peer transport
EXPOSE 9993/tcp 9993/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
	CMD zerotier-cli info >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
