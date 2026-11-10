/*
 * ZeroTier One - Network Virtualization Everywhere
 * Copyright (C) 2011-2016  ZeroTier, Inc.  https://www.zerotier.com/
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * World (planet) generator.
 *
 * Vendored from zerotier/ZeroTierOne attic/world/mkworld.cpp (blob
 * 6b9bbe8d0d28a2a13a7eab15f8458f761cdd4004, byte-identical in branch
 * "actions" at commit d2c745c and in commit 5e8e93518). See README.md.
 *
 * Upstream hard-codes the root list of the official ZeroTier planet inside
 * this file, which is useless for a self-hosted planet. This copy replaces that
 * block with a small line-oriented config reader (mkworld-upstream.cpp is the
 * unmodified file, kept for diffing) and adds a "verify" mode used by the
 * entrypoint and by the acceptance tests.
 *
 * Usage:
 *   mkworld build  <world.conf> <out.bin>   make a signed planet file
 *   mkworld verify <planet.bin>             parse + verify a planet file
 *
 * Build mode keeps upstream's key handling: it reads previous.c25519 and
 * current.c25519 from the current directory, creating them (same key pair,
 * self-signed) when absent. Keeping both files inside the data volume is what
 * makes a later world update signed by the key members already trust.
 *
 * world.conf format (one directive per line, '#' starts a comment):
 *   world_id=<decimal>            optional, default ZT_WORLD_ID_EARTH
 *   ts=<milliseconds>             optional, default now
 *   root=<identity.public>        starts a new root
 *   endpoint=<ip>/<port>          stable endpoint of the current root
 *                                 (IPv6 without brackets, port mandatory)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include <string>
#include <vector>
#include <algorithm>
#include <fstream>

#include <node/Constants.hpp>
#include <node/World.hpp>
#include <node/C25519.hpp>
#include <node/Identity.hpp>
#include <node/InetAddress.hpp>
#include <node/Utils.hpp>
#include <osdep/OSUtils.hpp>

using namespace ZeroTier;

static void usage()
{
	fprintf(stderr,
		"Usage: mkworld build <world.conf> <out.bin>" ZT_EOL_S
		"       mkworld verify <planet.bin>" ZT_EOL_S);
}

static std::string trim(const std::string &s)
{
	std::string::size_type b = 0;
	std::string::size_type e = s.size();
	while ((b < e) && ((s[b] == ' ') || (s[b] == '\t') || (s[b] == '\r') || (s[b] == '\n')))
		++b;
	while ((e > b) && ((s[e - 1] == ' ') || (s[e - 1] == '\t') || (s[e - 1] == '\r') || (s[e - 1] == '\n')))
		--e;
	return s.substr(b, e - b);
}

/*
 * Build mode: read the config, sign, and emit the serialized world.
 */
static int cmdBuild(const std::string &confPath, const std::string &outPath)
{
	std::string previous, current;
	if ((!OSUtils::readFile("previous.c25519", previous)) || (!OSUtils::readFile("current.c25519", current))) {
		C25519::Pair np(C25519::generate());
		previous = std::string();
		previous.append((const char *)np.pub.data, ZT_C25519_PUBLIC_KEY_LEN);
		previous.append((const char *)np.priv.data, ZT_C25519_PRIVATE_KEY_LEN);
		current = previous;
		OSUtils::writeFile("previous.c25519", previous);
		OSUtils::writeFile("current.c25519", current);
		fprintf(stderr, "INFO: created initial world keys: previous.c25519 and current.c25519 (both initially the same)" ZT_EOL_S);
	}

	if ((previous.length() != (ZT_C25519_PUBLIC_KEY_LEN + ZT_C25519_PRIVATE_KEY_LEN)) ||
		(current.length() != (ZT_C25519_PUBLIC_KEY_LEN + ZT_C25519_PRIVATE_KEY_LEN))) {
		fprintf(stderr, "FATAL: previous.c25519 or current.c25519 empty or invalid" ZT_EOL_S);
		return 1;
	}

	C25519::Pair previousKP;
	memcpy(previousKP.pub.data, previous.data(), ZT_C25519_PUBLIC_KEY_LEN);
	memcpy(previousKP.priv.data, previous.data() + ZT_C25519_PUBLIC_KEY_LEN, ZT_C25519_PRIVATE_KEY_LEN);
	C25519::Pair currentKP;
	memcpy(currentKP.pub.data, current.data(), ZT_C25519_PUBLIC_KEY_LEN);
	memcpy(currentKP.priv.data, current.data() + ZT_C25519_PUBLIC_KEY_LEN, ZT_C25519_PRIVATE_KEY_LEN);

	uint64_t id = ZT_WORLD_ID_EARTH;
	uint64_t ts = OSUtils::now();
	std::vector<World::Root> roots;

	std::ifstream in(confPath.c_str());
	if (!in.is_open()) {
		fprintf(stderr, "FATAL: cannot open world config %s" ZT_EOL_S, confPath.c_str());
		return 1;
	}

	unsigned long lineNo = 0;
	std::string line;
	while (std::getline(in, line)) {
		++lineNo;
		const std::string t(trim(line));
		if (t.empty() || (t[0] == '#'))
			continue;
		const std::string::size_type eq = t.find('=');
		if (eq == std::string::npos) {
			fprintf(stderr, "FATAL: %s:%lu: expected key=value" ZT_EOL_S, confPath.c_str(), lineNo);
			return 1;
		}
		const std::string key(trim(t.substr(0, eq)));
		const std::string val(trim(t.substr(eq + 1)));
		if (key == "world_id") {
			id = (uint64_t)strtoull(val.c_str(), (char **)0, 10);
		} else if (key == "ts") {
			ts = (uint64_t)strtoull(val.c_str(), (char **)0, 10);
		} else if (key == "root") {
			World::Root r;
			if ((val.length() < 32) || (!r.identity.fromString(val.c_str()))) {
				fprintf(stderr, "FATAL: %s:%lu: invalid root identity" ZT_EOL_S, confPath.c_str(), lineNo);
				return 1;
			}
			roots.push_back(r);
		} else if (key == "endpoint") {
			if (roots.empty()) {
				fprintf(stderr, "FATAL: %s:%lu: endpoint before any root" ZT_EOL_S, confPath.c_str(), lineNo);
				return 1;
			}
			const InetAddress a(val.c_str());
			if ((a.ss_family != AF_INET) && (a.ss_family != AF_INET6)) {
				fprintf(stderr, "FATAL: %s:%lu: invalid endpoint '%s'" ZT_EOL_S, confPath.c_str(), lineNo, val.c_str());
				return 1;
			}
			if (a.port() == 0) {
				fprintf(stderr, "FATAL: %s:%lu: endpoint '%s' has no port" ZT_EOL_S, confPath.c_str(), lineNo, val.c_str());
				return 1;
			}
			roots.back().stableEndpoints.push_back(a);
		} else {
			fprintf(stderr, "FATAL: %s:%lu: unknown directive '%s'" ZT_EOL_S, confPath.c_str(), lineNo, key.c_str());
			return 1;
		}
	}

	if (roots.empty()) {
		fprintf(stderr, "FATAL: world config '%s' defines no root" ZT_EOL_S, confPath.c_str());
		return 1;
	}
	for (std::vector<World::Root>::const_iterator r(roots.begin()); r != roots.end(); ++r) {
		if (r->stableEndpoints.empty()) {
			fprintf(stderr, "FATAL: root has no stable endpoint" ZT_EOL_S);
			return 1;
		}
	}

	fprintf(stderr, "INFO: generating and signing id=%llu ts=%llu roots=%u" ZT_EOL_S,
		(unsigned long long)id, (unsigned long long)ts, (unsigned int)roots.size());

	World nw = World::make(World::TYPE_PLANET, id, ts, currentKP.pub, roots, previousKP);

	Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> outtmp;
	nw.serialize(outtmp, false);
	World testw;
	testw.deserialize(outtmp, 0);
	if (testw != nw) {
		fprintf(stderr, "FATAL: serialization test failed!" ZT_EOL_S);
		return 1;
	}

	if (!OSUtils::writeFile(outPath.c_str(), std::string((const char *)outtmp.data(), outtmp.size()))) {
		fprintf(stderr, "FATAL: unable to write '%s'" ZT_EOL_S, outPath.c_str());
		return 1;
	}

	fprintf(stderr, "INFO: %s written with %u bytes of binary world data." ZT_EOL_S, outPath.c_str(), outtmp.size());
	printf("world=%s" ZT_EOL_S "world_id=%llu" ZT_EOL_S "timestamp=%llu" ZT_EOL_S "bytes=%u" ZT_EOL_S,
		outPath.c_str(), (unsigned long long)id, (unsigned long long)ts, outtmp.size());
	return 0;
}

/*
 * Verify mode: parse a planet file, re-check its signature, print what is in it.
 */
static int cmdVerify(const std::string &path)
{
	std::string bin;
	if (!OSUtils::readFile(path.c_str(), bin)) {
		fprintf(stderr, "FATAL: cannot read '%s'" ZT_EOL_S, path.c_str());
		return 1;
	}
	if (bin.empty() || (bin.size() > ZT_WORLD_MAX_SERIALIZED_LENGTH)) {
		fprintf(stderr, "FATAL: '%s' is not a plausible world file (%u bytes)" ZT_EOL_S, path.c_str(), (unsigned int)bin.size());
		return 1;
	}

	World w;
	try {
		Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> b;
		b.append(bin.data(), (unsigned int)bin.size());
		w.deserialize(b, 0);
	} catch (...) {
		fprintf(stderr, "FATAL: '%s' does not deserialize as a world" ZT_EOL_S, path.c_str());
		return 1;
	}

	Buffer<ZT_WORLD_MAX_SERIALIZED_LENGTH> signedForm;
	w.serialize(signedForm, true);
	const bool signatureValid = C25519::verify(w.updatesMustBeSignedBy(), signedForm.data(), signedForm.size(), w.signature());

	char signingKeyHex[(ZT_C25519_PUBLIC_KEY_LEN * 2) + 1];
	Utils::hex(w.updatesMustBeSignedBy().data, ZT_C25519_PUBLIC_KEY_LEN, signingKeyHex);
	signingKeyHex[ZT_C25519_PUBLIC_KEY_LEN * 2] = (char)0;

	const char *typeStr = (w.type() == World::TYPE_PLANET) ? "planet" : ((w.type() == World::TYPE_MOON) ? "moon" : "null");
	printf("type=%s" ZT_EOL_S, typeStr);
	printf("world_id=%llu" ZT_EOL_S, (unsigned long long)w.id());
	printf("timestamp=%llu" ZT_EOL_S, (unsigned long long)w.timestamp());
	printf("signature_valid=%s" ZT_EOL_S, signatureValid ? "true" : "false");
	printf("signing_key=%s" ZT_EOL_S, signingKeyHex);
	printf("roots=%u" ZT_EOL_S, (unsigned int)w.roots().size());
	for (unsigned int i = 0; i < w.roots().size(); ++i) {
		char idbuf[ZT_IDENTITY_STRING_BUFFER_LENGTH];
		w.roots()[i].identity.toString(false, idbuf);
		printf("root[%u].identity=%s" ZT_EOL_S, i, idbuf);
		for (unsigned int k = 0; k < w.roots()[i].stableEndpoints.size(); ++k) {
			char epbuf[64];
			w.roots()[i].stableEndpoints[k].toString(epbuf);
			printf("root[%u].endpoint[%u]=%s" ZT_EOL_S, i, k, epbuf);
		}
	}
	return signatureValid ? 0 : 2;
}

int main(int argc, char **argv)
{
	if ((argc == 4) && (!strcmp(argv[1], "build")))
		return cmdBuild(argv[2], argv[3]);
	if ((argc == 3) && (!strcmp(argv[1], "verify")))
		return cmdVerify(argv[2]);
	usage();
	return 1;
}
