// The C ABI in include/gdpcore.h over libgdp's pure (transport-free) parts:
// fingerprints, control-stream framing and video datagrams.
#include "gdpcore.h"

#include "gdp/cert_fingerprint.hpp"
#include "gdp/datagram.hpp"
#include "gdp/framing.hpp"
#include "gdp/version.hpp"
#include "gdp/video_reassembler.hpp"
#include "session.pb.h"

#include <cstring>
#include <string>
#include <vector>

namespace {

size_t encode_control(const gdp::session::ControlEnvelope &env, uint8_t *out, size_t cap) {
	std::vector<uint8_t> buf;
	if (!gdp::encode_frame(env, &buf) || buf.size() > cap) {
		return 0;
	}
	std::memcpy(out, buf.data(), buf.size());
	return buf.size();
}

gdpc_control_frame describe(const gdp::session::ControlEnvelope &env) {
	gdpc_control_frame f{};
	f.msg_case = static_cast<int32_t>(env.msg_case());
	f.encoded_size = env.ByteSizeLong();
	switch (env.msg_case()) {
	case gdp::session::ControlEnvelope::kPing: f.nonce = env.ping().nonce(); break;
	case gdp::session::ControlEnvelope::kPong: f.nonce = env.pong().nonce(); break;
	case gdp::session::ControlEnvelope::kKeyframeRequest: f.stream_id = env.keyframe_request().stream_id(); break;
	default: break;
	}
	return f;
}

gdp::VideoDatagramHeader to_gdp(const gdpc_video_header &h) {
	gdp::VideoDatagramHeader g;
	g.stream_id = h.stream_id;
	g.frame_id = h.frame_id;
	g.slice_idx = h.slice_idx;
	g.slice_count = h.slice_count;
	g.flags = h.keyframe ? gdp::VideoDatagramHeader::kFlagKeyframe : 0;
	g.pts = h.pts;
	g.host_latency = h.host_latency_us ? gdp::VideoDatagramHeader::host_latency_from_us(h.host_latency_us) : 0;
	return g;
}

gdpc_video_header from_gdp(const gdp::VideoDatagramHeader &g) {
	gdpc_video_header h{};
	h.stream_id = g.stream_id;
	h.frame_id = g.frame_id;
	h.slice_idx = g.slice_idx;
	h.slice_count = g.slice_count;
	h.keyframe = g.keyframe();
	h.pts = g.pts;
	h.host_latency_us = g.host_latency_us();
	return h;
}

} // namespace

struct gdpc_control_reader {
	gdp::FrameReader reader;
	gdp::session::ControlEnvelope env;
};

struct gdpc_video_reassembler {
	gdp::VideoFrameReassembler reassembler;
	gdp::VideoFrameReassembler::Frame frame;
};

extern "C" {

const char *gdpc_alpn(void) { return gdp::kAlpn; }
uint32_t gdpc_wire_version(void) { return gdp::kWireVersion; }

// --- Fingerprints ---

void gdpc_sha256(const uint8_t *data, size_t len, uint8_t out[32]) {
	auto digest = gdp::sha256(data, len);
	std::memcpy(out, digest.data(), digest.size());
}

void gdpc_sha256_hex(const uint8_t *data, size_t len, char out[GDPC_SHA256_HEX_LEN + 1]) {
	std::string hex = gdp::sha256_hex(data, len);
	std::memcpy(out, hex.c_str(), GDPC_SHA256_HEX_LEN + 1);
}

bool gdpc_is_sha256_hex(const char *s) { return s && gdp::is_sha256_hex(s); }

bool gdpc_format_fingerprint(const char *sha256_hex, char out[GDPC_FINGERPRINT_DISPLAY_LEN + 1]) {
	out[0] = '\0';
	if (!gdpc_is_sha256_hex(sha256_hex)) {
		return false;
	}
	std::string shown = gdp::format_fingerprint(sha256_hex);
	if (shown.size() != GDPC_FINGERPRINT_DISPLAY_LEN) {
		return false;
	}
	std::memcpy(out, shown.c_str(), GDPC_FINGERPRINT_DISPLAY_LEN + 1);
	return true;
}

// --- Framing ---

size_t gdpc_encode_ping(uint64_t nonce, uint8_t *out, size_t cap) {
	gdp::session::ControlEnvelope env;
	env.mutable_ping()->set_nonce(nonce);
	return encode_control(env, out, cap);
}

size_t gdpc_encode_pong(uint64_t nonce, uint8_t *out, size_t cap) {
	gdp::session::ControlEnvelope env;
	env.mutable_pong()->set_nonce(nonce);
	return encode_control(env, out, cap);
}

size_t gdpc_encode_keyframe_request(uint32_t stream_id, uint8_t *out, size_t cap) {
	gdp::session::ControlEnvelope env;
	env.mutable_keyframe_request()->set_stream_id(stream_id);
	return encode_control(env, out, cap);
}

gdpc_control_reader *gdpc_control_reader_create(void) { return new gdpc_control_reader; }
void gdpc_control_reader_destroy(gdpc_control_reader *reader) { delete reader; }

void gdpc_control_reader_set_max_frame_size(gdpc_control_reader *reader, size_t max) {
	reader->reader.set_max_frame_size(max);
}

gdpc_feed_result gdpc_control_reader_feed(gdpc_control_reader *reader, const uint8_t *data, size_t len,
	gdpc_control_frame_fn on_frame, void *ctx) {
	bool ok = reader->reader.feed_and_drain(data, len, &reader->env, [&] {
		gdpc_control_frame f = describe(reader->env);
		if (on_frame) {
			on_frame(ctx, &f);
		}
		return true;
	});
	if (ok) {
		return GDPC_FEED_OK;
	}
	return reader->reader.last_result() == gdp::FrameReader::Result::kTooLarge ? GDPC_FEED_TOO_LARGE
																			: GDPC_FEED_MALFORMED;
}

uint64_t gdpc_control_reader_error_code(const gdpc_control_reader *reader) { return reader->reader.error_code(); }

// --- Video datagrams ---

size_t gdpc_slice_payload_for(size_t max_datagram_size) { return gdp::slice_payload_for(max_datagram_size); }

bool gdpc_video_datagram_decode(const uint8_t *data, size_t len, gdpc_video_header *out, size_t *payload_offset,
	size_t *payload_len) {
	gdp::VideoDatagramHeader hdr;
	const uint8_t *payload = nullptr;
	size_t plen = 0;
	if (!gdp::VideoDatagramHeader::decode(data, len, &hdr, &payload, &plen)) {
		return false;
	}
	*out = from_gdp(hdr);
	*payload_offset = static_cast<size_t>(payload - data);
	*payload_len = plen;
	return true;
}

bool gdpc_slice_video_frame(const gdpc_video_header *header, const uint8_t *data, size_t len, size_t max_payload,
	gdpc_datagram_fn send, void *ctx) {
	return gdp::slice_video_frame(to_gdp(*header), data, len, max_payload,
		[&](const uint8_t *datagram, size_t datagram_len) { return send(ctx, datagram, datagram_len); });
}

gdpc_video_reassembler *gdpc_video_reassembler_create(void) { return new gdpc_video_reassembler; }
void gdpc_video_reassembler_destroy(gdpc_video_reassembler *reassembler) { delete reassembler; }

bool gdpc_video_reassembler_push(gdpc_video_reassembler *r, const uint8_t *datagram, size_t len,
	gdpc_video_frame_fn on_frame, void *ctx) {
	gdp::VideoDatagramHeader hdr;
	const uint8_t *payload = nullptr;
	size_t plen = 0;
	if (!gdp::VideoDatagramHeader::decode(datagram, len, &hdr, &payload, &plen)) {
		return false;
	}
	if (!r->reassembler.push(hdr, payload, plen, &r->frame)) {
		return false;
	}
	gdpc_video_frame f{};
	f.stream_id = r->frame.stream_id;
	f.frame_id = r->frame.frame_id;
	f.keyframe = r->frame.keyframe;
	f.pts = r->frame.pts;
	f.data = r->frame.data.data();
	f.len = r->frame.data.size();
	if (on_frame) {
		on_frame(ctx, &f);
	}
	return true;
}

} // extern "C"
