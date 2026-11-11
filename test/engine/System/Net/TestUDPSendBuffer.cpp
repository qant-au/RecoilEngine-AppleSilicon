/* This file is part of the Spring engine (GPL v2 or later), see LICENSE.html */

// A full UDP send buffer: what error does a non-blocking send_to return on
// this platform, and does UDPConnection retry and count drops? Written to
// check the would_block retry on Windows (PR #3293), where a full buffer gives
// WSAEWOULDBLOCK and asio's try_again is a different code. The sender gets the
// smallest send buffer the system allows and a receiver that never reads, so
// the buffer fills. Results are printed: whether a buffer fills at all depends
// on the platform's network stack, so only the counters' consistency is
// asserted, not that a send blocked.

#include "System/Net/UDPConnection.h"
#include "System/Net/Socket.h"
#include "System/GlobalConfig.h"
#include "Net/Protocol/BaseNetProtocol.h"
#include "System/Log/ILog.h"

#include <asio/ip/udp.hpp>
#include <catch_amalgamated.hpp>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace streflop {
	template<typename T> inline void streflop_init() {}
}

using asio::ip::udp;

namespace {
	// the smallest send buffer: on Windows a datagram may exceed it (it then
	// queues in the network stack), elsewhere a datagram larger than the buffer
	// fails with EMSGSIZE, so leave room for one
#ifdef _WIN32
	constexpr int SMALL_SEND_BUFFER = 1;
#else
	constexpr int SMALL_SEND_BUFFER = 4096;
#endif

	struct Pair {
		std::shared_ptr<udp::socket> sender;
		std::shared_ptr<udp::socket> receiver;
		udp::endpoint receiverAddr;
	};

	// UDP_SENDBUF_TARGET=<ip>:<port> sends across the network instead of to a
	// local receiver that never reads: on Windows a loopback send completes at
	// once whatever the buffer size, so only a real network card's queue fills.
	Pair MakePair(int sendBufferBytes)
	{
		Pair p;
		const char* target = std::getenv("UDP_SENDBUF_TARGET");
		if (target != nullptr && std::strchr(target, ':') != nullptr) {
			const std::string t(target);
			const size_t c = t.rfind(':');
			p.receiverAddr = udp::endpoint(asio::ip::make_address(t.substr(0, c)), (unsigned short)std::atoi(t.substr(c + 1).c_str()));
			p.sender = std::make_shared<udp::socket>(netcode::netservice, udp::endpoint(udp::v4(), 0));
			std::printf("[sendbuf] target %s (across the network)\n", target);
		} else {
			p.receiver = std::make_shared<udp::socket>(netcode::netservice, udp::endpoint(asio::ip::make_address("127.0.0.1"), 0));
			p.receiver->set_option(asio::socket_base::receive_buffer_size(1));
			p.receiverAddr = p.receiver->local_endpoint();
			p.sender = std::make_shared<udp::socket>(netcode::netservice, udp::endpoint(asio::ip::make_address("127.0.0.1"), 0));
		}
		p.sender->set_option(asio::socket_base::send_buffer_size(sendBufferBytes));
		p.sender->non_blocking(true);

		asio::socket_base::send_buffer_size got;
		p.sender->get_option(got);
		std::printf("[sendbuf] requested send buffer %d bytes, got %d\n", sendBufferBytes, got.value());
		return p;
	}
}

TEST_CASE("RawSendToFullBuffer")
{
	// what the platform returns when the buffer is full, with no engine code involved
	Pair p = MakePair(SMALL_SEND_BUFFER);
	std::vector<uint8_t> data(1400, 0xAB);
	std::map<std::string, int> results;

	for (int i = 0; i < 200000; ++i) {
		asio::error_code err;
		p.sender->send_to(asio::buffer(data), p.receiverAddr, 0, err);
		std::string key = !err ? "ok" : (err.value() == asio::error::would_block) ? "would_block" : (err.value() == asio::error::try_again) ? "try_again" : ("other:" + err.message());
		results[key] += 1;
	}
	std::printf("[sendbuf] would_block value %d, try_again value %d (equal on POSIX)\n", int(asio::error::would_block), int(asio::error::try_again));
	for (const auto& r: results)
		std::printf("[sendbuf] raw send_to %-12s %d\n", r.first.c_str(), r.second);

	int total = 0;
	for (const auto& r: results)
		total += r.second;
	CHECK(total == 200000);
}

TEST_CASE("UDPConnectionFullBuffer")
{
	// the engine path: UDPConnection::SendPacket's retry and its drop counter
	globalConfig.linkOutgoingBandwidth = 0; // no throttle: fill the buffer as fast as possible
	Pair p = MakePair(SMALL_SEND_BUFFER);
	netcode::UDPConnection conn(p.sender, p.receiverAddr);
	conn.Unmute();

	std::vector<uint8_t> payload(1000, 0x5A);
	for (int round = 0; round < 400; ++round) {
		for (int i = 0; i < 50; ++i)
			conn.SendData(CBaseNetProtocol::Get().SendLuaMsg(0, 0, 0, payload));
		conn.Flush(true);
	}
	const std::string stats = conn.Statistics();
	std::printf("%s", stats.c_str());

	unsigned sentBytes = 0, sentPackets = 0, retried = 0, retriedSent = 0, dropped = 0;
	CHECK(std::sscanf(stats.c_str(), "[UDPConnection::Statistics]\n\t%u bytes sent in %u packets", &sentBytes, &sentPackets) >= 0);
	const char* r = std::strstr(stats.c_str(), "sends retried");
	const char* d = std::strstr(stats.c_str(), "outgoing packets dropped");
	REQUIRE(r != nullptr);
	REQUIRE(d != nullptr);
	for (const char* s = r; s > stats.c_str() && s[-1] != '\t'; --s) r = s - 1;
	for (const char* s = d; s > stats.c_str() && s[-1] != '\t'; --s) d = s - 1;
	std::sscanf(r, "%u sends retried after a full send buffer, %u of them sent", &retried, &retriedSent);
	std::sscanf(d, "%u", &dropped);
	std::printf("[sendbuf] retried %u, retried and sent %u, dropped %u\n", retried, retriedSent, dropped);

	// a retry either sent the packet or the packet was dropped
	CHECK(retriedSent <= retried);
	CHECK(dropped <= retried + 400 * 50);
}
