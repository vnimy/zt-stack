#!/bin/bash
# Build the vendored mkworld. Mirrors upstream attic/world/build.sh, with -I. so
# that the "<node/...>" includes resolve inside this directory.
set -euo pipefail
cd "$(dirname "$0")"

CXX="${CXX:-c++}"
exec $CXX -std=c++11 -O2 -fstack-protector -I. \
	-o mkworld \
	node/C25519.cpp node/Salsa20.cpp node/SHA512.cpp node/Identity.cpp \
	node/Utils.cpp node/InetAddress.cpp osdep/OSUtils.cpp mkworld.cpp \
	-lm "$@"
