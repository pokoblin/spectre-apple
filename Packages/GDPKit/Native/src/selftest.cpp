// gdpc_selftest_quic_loopback(): libgdp's QUIC transport end to end, both
// roles in this process, over 127.0.0.1. Modelled on
// third_party/ghost/libgdp/tests/transport_test.cpp, but self-contained: the
// certificate comes from OpenSSL's API rather than the openssl CLI (there
// is none on iOS) and lives in a caller-chosen scratch directory.
#include "gdpcore.h"

#include "gdp/cert_fingerprint.hpp"
#include "gdp/clock.hpp"
#include "gdp/datagram.hpp"
#include "gdp/framing.hpp"
#include "gdp/transport.hpp"
#include "gdp/version.hpp"
#include "gdp/video_reassembler.hpp"
#include "session.pb.h"

#include "cert_util.hpp"

#include <openssl/rand.h>

#include <poll.h>
#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace {

double ms_since(uint64_t start_us) { return static_cast<double>(gdp::monotonic_us() - start_us) / 1000.0; }

// Pumps both transports until `done()` or the deadline (gdp::monotonic_us()).
bool pump_until(gdp::Transport &a, gdp::Transport &b, uint64_t deadline_us, const std::function<bool()> &done) {
	while (!done()) {
		if (gdp::monotonic_us() > deadline_us) {
			return false;
		}
		struct pollfd fds[2] = {{a.notify_fd(), POLLIN, 0}, {b.notify_fd(), POLLIN, 0}};
		poll(fds, 2, 10);
		a.dispatch();
		b.dispatch();
	}
	return true;
}

void fail(gdpc_selftest_result *out, const std::string &why) {
	out->ok = false;
	std::snprintf(out->error, sizeof(out->error), "%s", why.c_str());
}

} // namespace

extern "C" void gdpc_selftest_quic_loopback(const char *scratch_dir, int timeout_ms, gdpc_selftest_result *out) {
	*out = gdpc_selftest_result{};
	const uint64_t start_us = gdp::monotonic_us();
	const uint64_t deadline_us = start_us + static_cast<uint64_t>(timeout_ms) * 1000;

	gdpcore::SelfSignedCert cert;
	if (std::string err = cert.generate(scratch_dir ? scratch_dir : "/tmp"); !err.empty()) {
		return fail(out, "certificate: " + err);
	}

	// Transports first: connections must be destroyed before them.
	gdp::Transport server_transport;
	gdp::Transport client_transport;
	std::unique_ptr<gdp::Connection> server_conn;
	std::unique_ptr<gdp::Connection> client_conn;

	// What the server does: answer each Ping with a Pong, then send one
	// video frame as sliced datagrams.
	std::vector<uint8_t> video_frame(48 * 1024);
	for (size_t i = 0; i < video_frame.size(); i++) {
		video_frame[i] = static_cast<uint8_t>(i * 131 + 7);
	}
	gdp::FrameReader server_reader;
	gdp::session::ControlEnvelope server_env;
	bool server_saw_input = false;
	std::string server_error;

	auto on_new_connection = [&](std::unique_ptr<gdp::Connection> conn) {
		server_conn = std::move(conn);
		server_conn->on_input_stream = [&](gdp::Stream *) { server_saw_input = true; };
		server_conn->on_control_stream = [&](gdp::Stream *s) {
			s->on_data = [&, s](const uint8_t *data, size_t len) {
				bool ok = server_reader.feed_and_drain(data, len, &server_env, [&] {
					if (server_env.has_ping()) {
						gdp::session::ControlEnvelope pong;
						pong.mutable_pong()->set_nonce(server_env.ping().nonce());
						s->send_message(pong);

						gdp::VideoDatagramHeader hdr;
						hdr.frame_id = 1;
						hdr.flags = gdp::VideoDatagramHeader::kFlagKeyframe;
						hdr.pts = 1234;
						size_t payload = gdp::slice_payload_for(server_conn->max_datagram_size());
						gdp::slice_video_frame(hdr, video_frame.data(), video_frame.size(), payload,
							[&](const uint8_t *dgram, size_t dlen) {
								if (!server_conn->send_datagram(dgram, dlen)) {
									server_error = "server send_datagram refused " + std::to_string(dlen) + " bytes";
									return false;
								}
								return true;
							});
					}
					return true;
				});
				if (!ok) server_error = "server: malformed control frame";
			};
		};
	};

	// Listen on a random high port (Transport::listen() can't report an
	// ephemeral one), retrying past ports in use.
	uint16_t port = 0;
	for (int attempt = 0; attempt < 16 && port == 0; attempt++) {
		uint16_t candidate = 0;
		RAND_bytes(reinterpret_cast<unsigned char *>(&candidate), sizeof(candidate));
		candidate = static_cast<uint16_t>(49152 + candidate % 16000);
		bool in_use = false;
		if (server_transport.listen(candidate, gdp::kAlpn, cert.cert_path, cert.key_path, on_new_connection,
				&in_use)) {
			port = candidate;
		} else if (!in_use) {
			return fail(out, "Transport::listen failed");
		}
	}
	if (port == 0) return fail(out, "no free UDP port");
	out->port = port;

	client_conn = client_transport.connect("127.0.0.1", port, gdp::kAlpn);
	if (!client_conn) return fail(out, "Transport::connect returned null");
	bool connected = false;
	bool shut_down = false;
	client_conn->on_state_changed = [&](gdp::ConnectionState state) {
		connected = connected || state == gdp::ConnectionState::kConnected;
		shut_down = shut_down || state == gdp::ConnectionState::kShutdown;
	};
	if (!pump_until(client_transport, server_transport, deadline_us, [&] { return connected || shut_down; }) ||
		!connected) {
		return fail(out, "handshake did not complete: " + client_conn->shutdown_reason());
	}
	out->handshake_ms = ms_since(start_us);

	// Host pinning input (§2.3): the client must see exactly our certificate.
	std::snprintf(out->cert_sha256, sizeof(out->cert_sha256), "%s", client_conn->peer_certificate_sha256().c_str());
	if (client_conn->peer_certificate_sha256() != cert.sha256) {
		return fail(out, "fingerprint mismatch: saw " + client_conn->peer_certificate_sha256() + ", expected " +
			cert.sha256);
	}

	gdp::Stream *control = client_conn->open_control_stream();
	gdp::Stream *input = control ? client_conn->open_input_stream() : nullptr;
	if (!control || !input) return fail(out, "could not open the control and input streams");

	const uint64_t nonce = 0x5eC7'0000'0000'0001ull;
	bool got_pong = false;
	gdp::FrameReader client_reader;
	gdp::session::ControlEnvelope client_env;
	control->on_data = [&](const uint8_t *data, size_t len) {
		client_reader.feed_and_drain(data, len, &client_env, [&] {
			got_pong = got_pong || (client_env.has_pong() && client_env.pong().nonce() == nonce);
			return true;
		});
	};
	gdp::VideoFrameReassembler reassembler;
	bool got_frame = false;
	bool frame_matches = false;
	client_conn->on_datagram = [&](const uint8_t *data, size_t len, uint64_t) {
		out->datagrams_received++;
		gdp::VideoDatagramHeader hdr;
		const uint8_t *payload = nullptr;
		size_t plen = 0;
		gdp::VideoFrameReassembler::Frame frame;
		if (gdp::VideoDatagramHeader::decode(data, len, &hdr, &payload, &plen) &&
			reassembler.push(hdr, payload, plen, &frame)) {
			got_frame = true;
			frame_matches = frame.keyframe && frame.pts == 1234 && frame.data == video_frame;
		}
	};

	// Give path MTU discovery a moment so the frame goes out in full-size
	// slices, as it would in a session; not required to pass.
	pump_until(client_transport, server_transport, std::min(deadline_us, gdp::monotonic_us() + 1'000'000),
		[&] { return server_conn && server_conn->max_datagram_size() >= 1400; });

	gdp::session::ControlEnvelope ping;
	ping.mutable_ping()->set_nonce(nonce);
	if (!control->send_message(ping)) return fail(out, "send_message(Ping) failed");

	if (!pump_until(client_transport, server_transport, deadline_us,
			[&] { return (got_pong && got_frame) || !server_error.empty(); })) {
		return fail(out, std::string("timed out waiting for ") + (got_pong ? "" : "the Pong ") +
			(got_frame ? "" : "the video frame"));
	}
	if (!server_error.empty()) return fail(out, server_error);
	if (!server_saw_input) return fail(out, "server never saw the input stream");
	if (!frame_matches) return fail(out, "reassembled video frame differs from what was sent");

	out->rtt_us = client_conn->rtt_us();
	out->max_datagram_size = client_conn->max_datagram_size();
	client_conn->close();
	pump_until(client_transport, server_transport, gdp::monotonic_us() + 200'000, [&] { return shut_down; });
	out->total_ms = ms_since(start_us);
	out->ok = true;
}
