#include "session_client.hpp"

#include "keep_alive.hpp"
#include "local_serve.hpp"

#include "gdp/cert_fingerprint.hpp"
#include "gdp/clipboard.hpp"
#include "gdp/clock.hpp"
#include "gdp/datagram.hpp"
#include "gdp/error_codes.hpp"
#include "gdp/file_transfer.hpp"
#include "gdp/framing.hpp"
#include "gdp/gamepad.hpp"
#include "gdp/version.hpp"
#include "session.pb.h"

#include <algorithm>
#include <unistd.h>
#include <cmath>

namespace gdpcore {

namespace {

constexpr uint32_t kMaxCursorSide = 384;            // §7.4
constexpr size_t kMaxDiagnosticsText = 512 * 1024;  // §7.11
constexpr size_t kMaxEarlyFrames = 8;
constexpr uint64_t kKeyframeRequestIntervalUs = 1'000'000;

int32_t diff32(uint32_t a, uint32_t b) {
	return static_cast<int32_t>(a - b);
}

uint64_t code(gdp::ErrorCode c) {
	return static_cast<uint64_t>(c);
}

Output to_output(const gdp::session::OutputDescriptor &d) {
	Output o;
	o.stream_id = d.stream_id();
	o.width = d.display().width();
	o.height = d.display().height();
	o.refresh_mhz = d.display().refresh_mhz();
	o.scale = d.display().scale();
	o.matrix = d.color().matrix();
	o.range = d.color().range();
	o.primaries = d.color().primaries();
	o.transfer = d.color().transfer();
	o.bit_depth = d.color().bit_depth();
	o.chroma = d.color().chroma();
	return o;
}

} // namespace

SessionClient::SessionClient(Callbacks callbacks) : cb_(std::move(callbacks)) {}

SessionClient::~SessionClient() {
	// Destroying the connection without reporting: the owner is going away.
	closed_reported_ = true;
}

bool SessionClient::start(const Config &config, std::string *error) {
	auto failed = [&](const std::string &why) {
		if (error) *error = why;
		return false;
	};
	if (conn_) return failed("already started");
	// §2.3: never open a session connection without a well-formed fingerprint.
	if (!gdp::is_sha256_hex(config.cert_sha256)) return failed("certificate fingerprint is not 64 lowercase hex digits");
	if (config.host.empty() || config.port == 0) return failed("no host or port");
	if (config.codecs.empty()) return failed("no video codec to offer");
	if (config.network_profile < 0 || config.network_profile > 3) return failed("unknown network profile");

	config_ = config;
	on_certificate = [this](const std::string &presented) { return presented == config_.cert_sha256; };
	if (!connect_transport(config.host, config.port, gdp::kAlpn)) return failed("could not start the connection");
	// §2.1: an idle viewer must not time out. StatsReport (every 250 ms,
	// §7.5) keeps the connection busy once the session is accepted; PINGs
	// cover whatever quiet that leaves.
	conn_->set_keep_alive(kKeepAliveMs);
	return true;
}

void SessionClient::on_connected() {
	control_ = conn_->open_control_stream();
	input_ = control_ ? conn_->open_input_stream() : nullptr;
	if (!control_ || !input_) {
		fail(code(gdp::ErrorCode::kNone), "could not open the control and input streams");
		return;
	}
	control_->on_data = [this](const uint8_t *data, size_t len) { handle_control_data(data, len); };
	// Without `hid` the host sends nothing on the input stream; ignore it (§8.4).
	input_->on_data = [](const uint8_t *, size_t) {};
	conn_->on_datagram = [this](const uint8_t *data, size_t len, uint64_t arrival_us) {
		handle_datagram(data, len, arrival_us);
	};

	gdp::session::ControlEnvelope env;
	auto *hello = env.mutable_hello();
	hello->set_token(config_.token);
	hello->set_take_over(config_.take_over);
	hello->set_via_gateway(false); // §6.10: a client always sends false
	hello->set_network_profile(static_cast<gdp::session::NetworkProfile>(config_.network_profile));
	if (config_.display_width && config_.display_height) {
		auto *d = hello->add_displays();
		d->set_width(config_.display_width);
		d->set_height(config_.display_height);
		d->set_refresh_mhz(config_.display_refresh_mhz);
		d->set_scale(config_.display_scale);
	}
	for (const auto &c : config_.codecs) hello->add_codecs(c);
	for (const auto &c : config_.capabilities) hello->add_capabilities(c);
	for (const auto &d : config_.decoders) hello->add_decoders(d);
	hello->set_client_name(config_.client_name);
	send_control(env);
}

void SessionClient::on_connection_shutdown() {
	if (local_close_) {
		report_closed(local_close_->first, local_close_->second);
		return;
	}
	if (certificate_rejected()) {
		std::string presented = conn_ ? conn_->peer_certificate_sha256() : std::string();
		report_closed(0, "the host's certificate " + (presented.empty() ? std::string("(none)") : presented) +
				" is not the expected " + config_.cert_sha256);
		return;
	}
	uint64_t c = conn_ ? conn_->shutdown_error_code() : 0;
	// libgdp leaves the reason empty only for the peer's ordinary close
	// (application code 0); timeouts, resets and socket errors carry one.
	bool lost = c == 0 && rejected_reason_.empty() && conn_ && !conn_->shutdown_reason().empty();
	std::string reason;
	if (!rejected_reason_.empty()) {
		reason = "rejected: " + rejected_reason_;
	} else if (c != 0) {
		reason = gdp::describe_error_code(c);
	} else if (conn_ && !conn_->shutdown_reason().empty()) {
		reason = conn_->shutdown_reason();
	}
	report_closed(c, reason, lost);
}

void SessionClient::report_closed(uint64_t c, const std::string &reason, bool connection_lost) {
	if (closed_reported_) return;
	closed_reported_ = true;
	accepted_ = false;
	control_ = nullptr;
	input_ = nullptr;
	// Every transfer still going ends with the connection, reported first.
	while (!files_.empty()) finish_file(files_.begin()->second.get(), FileOutcome::kLost);
	copied_lists_.clear();
	if (cb_.closed) cb_.closed(c, reason, certificate_rejected(), connection_lost);
}

void SessionClient::fail(uint64_t c, const std::string &reason) {
	if (local_close_ || closed_reported_) return;
	local_close_ = std::make_pair(c, reason);
	accepted_ = false;
	if (conn_ && conn_->state() != gdp::ConnectionState::kShutdown) {
		conn_->close(c);
	} else {
		report_closed(c, reason);
	}
}

void SessionClient::close() {
	fail(0, "closed");
}

// --- Control stream ---

void SessionClient::handle_control_data(const uint8_t *data, size_t len) {
	gdp::session::ControlEnvelope env;
	bool ok = control_reader_.feed_and_drain(data, len, &env, [&] { return handle_envelope(env); });
	if (!ok) {
		fail(control_reader_.error_code(), control_reader_.last_result() == gdp::FrameReader::Result::kTooLarge
				? "the host sent an oversized control frame"
				: "the host sent a malformed control frame");
	}
}

// Returns false to stop draining (the connection is being closed).
bool SessionClient::handle_envelope(const gdp::session::ControlEnvelope &env) {
	using E = gdp::session::ControlEnvelope;
	if (local_close_ || closed_reported_) return false;

	if (!accepted_) {
		// Before establishment only the answer to SessionHello counts (§7.1).
		if (env.msg_case() == E::kAccept) return handle_accept(env.accept());
		if (env.msg_case() == E::kReject) {
			rejected_reason_ = env.reject().reason();
			fail(0, "rejected: " + rejected_reason_);
			return false;
		}
		return true;
	}

	switch (env.msg_case()) {
	case E::kPing: {
		gdp::session::ControlEnvelope pong;
		pong.mutable_pong()->set_nonce(env.ping().nonce());
		send_control(pong);
		break;
	}
	case E::kGatewayPath:
		upstream_rtt_us_ = env.gateway_path().upstream_rtt_us();
		break;
	case E::kDisplaysChanged: {
		std::vector<Output> outputs;
		for (const auto &o : env.displays_changed().outputs()) outputs.push_back(to_output(o));
		if (cb_.displays_changed) cb_.displays_changed(outputs);
		break;
	}
	case E::kCursorShape: {
		const auto &c = env.cursor_shape();
		// §7.4: ignore anything oversized or whose bytes don't match its size.
		if (c.width() > kMaxCursorSide || c.height() > kMaxCursorSide) break;
		if (c.argb8888().size() != size_t(c.width()) * c.height() * 4) break;
		if (cb_.cursor_shape) {
			cb_.cursor_shape(c.width(), c.height(), c.hotspot_x(), c.hotspot_y(),
				reinterpret_cast<const uint8_t *>(c.argb8888().data()));
		}
		break;
	}
	case E::kCursorPosition:
		if (cb_.cursor_position) cb_.cursor_position(env.cursor_position().x(), env.cursor_position().y());
		break;
	case E::kNetworkProfileChanged:
		if (cb_.network_profile_changed) cb_.network_profile_changed(env.network_profile_changed().profile());
		break;
	case E::kDiagnosticsRequest:
		diagnostics_pending_ = true;
		if (cb_.diagnostics_requested) cb_.diagnostics_requested();
		break;
	case E::kFileList: {
		// §7.12: only with `file` in effect; at most the limit's entries of
		// what was copied, and with file-clipboard, what is in its folders.
		if (!file_ || !cb_.file_list) break;
		std::vector<FileListEntry> files;
		size_t copied = 0;
		for (const auto &f : env.file_list().files()) {
			uint32_t parent = file_clipboard_ ? f.parent() : 0;
			if (parent == 0 && ++copied > gdp::kMaxFileListEntries) break;
			if (files.size() == gdp::kMaxFileListTotal) break;
			// A parent is a folder before it, or the list means nothing.
			if (parent > files.size() || (parent && !files[parent - 1].directory)) break;
			files.push_back({f.name(), f.size(), f.modified_unix_ms(), f.directory(), parent,
				file_clipboard_ && f.directory() && f.unlisted()});
		}
		cb_.file_list(env.file_list().list_id(), files);
		break;
	}
	case E::kFileFetch:
		handle_fetch(env.file_fetch());
		break;
	case E::kClipboard: {
		const auto &c = env.clipboard();
		// §7.9: text/plain only, never empty, never over the limit.
		if (!clipboard_ || c.mime_type() != gdp::kClipboardMimeText) break;
		if (c.data().empty() || c.data().size() > gdp::kMaxClipboardBytes) break;
		if (cb_.clipboard_text) cb_.clipboard_text(reinterpret_cast<const uint8_t *>(c.data().data()), c.data().size());
		break;
	}
	default:
		// A second SessionAccept/Reject, client-to-host messages, messages of
		// capabilities not in effect, and anything newer: ignored (§3.1, §7.1).
		break;
	}
	return true;
}

bool SessionClient::handle_accept(const gdp::session::SessionAccept &accept) {
	// §6.6: the codec must be one we offered.
	if (std::find(config_.codecs.begin(), config_.codecs.end(), accept.codec()) == config_.codecs.end()) {
		fail(code(gdp::ErrorCode::kNoCommonCodec), "the host chose codec '" + accept.codec() + "', which was not offered");
		return false;
	}

	AcceptInfo info;
	info.codec = accept.codec();
	for (const auto &o : accept.outputs()) info.outputs.push_back(to_output(o));
	info.bitrate_ceiling_bps = accept.bitrate_ceiling_bps();
	if (accept.has_audio()) {
		info.has_audio = true;
		info.audio_codec = accept.audio().codec();
		info.audio_sample_rate_hz = accept.audio().sample_rate_hz();
		info.audio_channels = accept.audio().channels();
		info.audio_frame_ms = accept.audio().frame_ms();
	}
	// §6.7: only what we offered can be in effect; anything else is ignored.
	for (const auto &c : accept.capabilities()) {
		bool offered = std::find(config_.capabilities.begin(), config_.capabilities.end(), c) != config_.capabilities.end();
		bool duplicate = std::find(info.capabilities.begin(), info.capabilities.end(), c) != info.capabilities.end();
		if (offered && !duplicate) info.capabilities.push_back(c);
	}
	// §6.8, §10.1: the microphone's format comes with the capability.
	bool microphone = std::find(info.capabilities.begin(), info.capabilities.end(), "microphone") != info.capabilities.end();
	if (microphone && accept.has_microphone()) {
		info.has_microphone = true;
		info.microphone_codec = accept.microphone().codec();
		info.microphone_sample_rate_hz = accept.microphone().sample_rate_hz();
		info.microphone_channels = accept.microphone().channels();
		info.microphone_frame_ms = accept.microphone().frame_ms();
	}
	info.network_profile = accept.network_profile();
	info.via_gateway = accept.via_gateway();
	info.encoder = accept.encoder();
	info.host_user = accept.host_user();
	info.host_name = accept.host_name();

	capabilities_ = info.capabilities;
	microphone_ = info.has_microphone;
	microphone_seq_ = 0; // §10.1
	clipboard_ = std::find(capabilities_.begin(), capabilities_.end(), gdp::kCapabilityClipboard) != capabilities_.end();
	gamepad_ = std::find(capabilities_.begin(), capabilities_.end(), gdp::kCapabilityGamepad) != capabilities_.end();
	file_ = std::find(capabilities_.begin(), capabilities_.end(), gdp::kCapabilityFile) != capabilities_.end();
	// §7.12: only with what it builds on, whatever the host lists.
	file_clipboard_ = file_ && clipboard_ &&
		std::find(capabilities_.begin(), capabilities_.end(), gdp::kCapabilityFileClipboard) != capabilities_.end();
	refine_ = std::find(capabilities_.begin(), capabilities_.end(), gdp::kCapabilityRefine) != capabilities_.end();
	accepted_ = true;
	// §11: our session clock starts now.
	session_epoch_us_ = gdp::monotonic_us();
	for (auto &st : streams_) st.stats.start(session_epoch_us_);
	if (cb_.accepted) cb_.accepted(info);
	// §7.8: every connection starts unpaused.
	if (accepted_ && refine_ && refine_paused_) send_refine_pause();

	while (!early_frames_.empty() && accepted_) {
		auto frame = std::move(early_frames_.front());
		early_frames_.pop_front();
		deliver(frame);
	}
	return accepted_;
}

void SessionClient::send_control(const gdp::session::ControlEnvelope &env) {
	if (control_) control_->send_message(env);
}

void SessionClient::send_input(gdp::session::InputEnvelope &env) {
	if (!accepted_ || !input_) return;
	env.set_client_time_us(gdp::monotonic_us());
	input_->send_message(env);
}

// --- Datagrams ---

SessionClient::StreamState &SessionClient::stream(uint8_t stream_id) {
	for (auto &st : streams_) {
		if (st.stats.stream_id() == stream_id) return st;
	}
	streams_.emplace_back(stream_id);
	if (accepted_) streams_.back().stats.start(session_epoch_us_);
	return streams_.back();
}

void SessionClient::handle_datagram(const uint8_t *data, size_t len, uint64_t arrival_us) {
	if (local_close_ || closed_reported_) return;
	auto channel = gdp::peek_channel(data, len);
	if (!channel) return;

	if (*channel == gdp::DatagramChannel::kAudio) {
		gdp::AudioDatagramHeader h;
		const uint8_t *payload = nullptr;
		size_t plen = 0;
		if (accepted_ && gdp::AudioDatagramHeader::decode(data, len, &h, &payload, &plen) && cb_.audio_packet) {
			cb_.audio_packet(h.seq, h.pts, payload, plen);
		}
		return;
	}
	if (*channel != gdp::DatagramChannel::kVideo) return; // §3.2: drop what we don't use

	gdp::VideoDatagramHeader h;
	const uint8_t *payload = nullptr;
	size_t plen = 0;
	if (!gdp::VideoDatagramHeader::decode(data, len, &h, &payload, &plen)) return;
	StreamState &st = stream(h.stream_id);
	if (accepted_) st.stats.on_datagram(h, len, arrival_us, session_epoch_us_);
	gdp::VideoFrameReassembler::Frame frame;
	if (reassembler_.push(h, payload, plen, &frame)) handle_video_frame(frame);
}

void SessionClient::drop_until_keyframe(StreamState &st) {
	st.awaiting_keyframe = true;
	// The host repairs reported losses by itself (§7.5); a request covers
	// what it can't see, such as a first keyframe that never arrived.
	uint64_t now = gdp::monotonic_us();
	if (accepted_ && now - st.last_keyframe_request_us >= kKeyframeRequestIntervalUs) {
		st.last_keyframe_request_us = now;
		request_keyframe(st.stats.stream_id());
	}
}

void SessionClient::handle_video_frame(gdp::VideoFrameReassembler::Frame &frame) {
	StreamState &st = stream(frame.stream_id);
	bool gap = st.stats.has_frames() && diff32(frame.frame_id, st.stats.highest_frame_id()) > 1;
	st.stats.on_frame_completed(frame.frame_id);
	if (gap && config_.drop_until_keyframe_after_loss) st.awaiting_keyframe = true;

	if (st.awaiting_keyframe && !frame.keyframe) {
		st.stats.on_frame_discarded(frame.frame_id);
		frames_dropped_++;
		drop_until_keyframe(st);
		return;
	}
	if (frame.keyframe) st.awaiting_keyframe = false;

	if (!accepted_) {
		if (early_frames_.size() == kMaxEarlyFrames) {
			st.stats.on_frame_discarded(early_frames_.front().frame_id);
			early_frames_.pop_front();
		}
		early_frames_.push_back(std::move(frame));
		return;
	}
	deliver(frame);
}

void SessionClient::deliver(const gdp::VideoFrameReassembler::Frame &frame) {
	VideoFrame f;
	f.stream_id = frame.stream_id;
	f.frame_id = frame.frame_id;
	f.keyframe = frame.keyframe;
	f.pts = frame.pts;
	f.data = frame.data.data();
	f.len = frame.data.size();
	RefineFrameLayer layer;
	if (refine_) {
		// §9.5: every payload is a container; a malformed one is dropped
		// and reported lost, so the host sends its clears and tiles again.
		if (!gdp::refine_parse_frame(frame.data.data(), frame.data.size(), &f.data, &f.len, &refine_layer_)) {
			mark_frame_discarded(frame.stream_id, frame.frame_id);
			return;
		}
		// The wire's 3-byte pixels, opaque BGRA for the overlay plane.
		refine_bgra_.resize(refine_layer_.tile_pixels.size() / gdp::kRefineBytesPerPixel * 4);
		const uint8_t *in = refine_layer_.tile_pixels.data();
		uint8_t *out = refine_bgra_.data();
		for (const gdp::RefineRect &t : refine_layer_.tiles) {
			for (uint16_t row = 0; row < t.height; row++) {
				gdp::refine_unpack_row(in, out, t.width);
				in += size_t(t.width) * gdp::kRefineBytesPerPixel;
				out += size_t(t.width) * 4;
			}
		}
		layer.reset = refine_layer_.reset;
		layer.clears = refine_layer_.clears.data();
		layer.clear_count = refine_layer_.clears.size();
		layer.tiles = refine_layer_.tiles.data();
		layer.tile_count = refine_layer_.tiles.size();
		layer.bgra = refine_bgra_.data();
		layer.bgra_len = refine_bgra_.size();
		f.refine = &layer;
	}
	bool used = cb_.video_frame ? cb_.video_frame(f) : false;
	if (used) {
		frames_delivered_++;
	} else {
		mark_frame_discarded(frame.stream_id, frame.frame_id);
	}
}

void SessionClient::mark_frame_discarded(uint8_t stream_id, uint32_t frame_id) {
	StreamState &st = stream(stream_id);
	st.stats.on_frame_discarded(frame_id);
	drop_until_keyframe(st);
}

// --- Commands ---

void SessionClient::send_stats_report() {
	if (!accepted_ || !conn_) return;
	// The same 250 ms tick serves the file offers' reply deadline.
	expire_file_offers();
	forget_copied_lists();
	if (!accepted_) return;
	gdp::session::ControlEnvelope env;
	auto *report = env.mutable_stats();
	report->set_rtt_us(conn_->rtt_us() + upstream_rtt_us_);
	uint64_t now = gdp::monotonic_us();
	for (auto &st : streams_) {
		gdp::session::StreamStats s;
		if (st.stats.take(now, &s)) *report->add_streams() = std::move(s);
	}
	send_control(env);
	stats_reports_sent_++;
}

void SessionClient::record_frame_timing(uint32_t decode_us, uint32_t present_us) {
	for (auto &st : streams_) st.stats.record_timing(decode_us, present_us);
}

void SessionClient::request_keyframe(uint32_t stream_id) {
	if (!accepted_) return;
	gdp::session::ControlEnvelope env;
	env.mutable_keyframe_request()->set_stream_id(stream_id);
	send_control(env);
}

void SessionClient::request_resolution(uint32_t stream_id, uint32_t width, uint32_t height) {
	if (!accepted_) return;
	gdp::session::ControlEnvelope env;
	auto *r = env.mutable_resolution_change();
	r->set_stream_id(stream_id);
	r->mutable_display()->set_width(width);
	r->mutable_display()->set_height(height);
	send_control(env);
}

void SessionClient::send_logout() {
	if (!accepted_) return;
	gdp::session::ControlEnvelope env;
	env.mutable_logout_request();
	send_control(env);
}

void SessionClient::send_diagnostics_report(const uint8_t *text, size_t len) {
	if (!accepted_ || !diagnostics_pending_) return;
	diagnostics_pending_ = false;
	gdp::session::ControlEnvelope env;
	env.mutable_diagnostics_report()->set_text(reinterpret_cast<const char *>(text), std::min(len, kMaxDiagnosticsText));
	send_control(env);
}

void SessionClient::send_clipboard_text(const uint8_t *text, size_t len) {
	if (!accepted_ || !clipboard_ || len == 0 || len > gdp::kMaxClipboardBytes) return;
	gdp::session::ControlEnvelope env;
	auto *c = env.mutable_clipboard();
	c->set_mime_type(gdp::kClipboardMimeText);
	c->set_data(reinterpret_cast<const char *>(text), len);
	send_control(env);
}

void SessionClient::set_refine_paused(bool paused) {
	if (paused == refine_paused_) return;
	refine_paused_ = paused;
	if (accepted_ && refine_) send_refine_pause();
}

void SessionClient::send_refine_pause() {
	gdp::session::ControlEnvelope env;
	env.mutable_refine_pause()->set_paused(refine_paused_);
	send_control(env);
}

void SessionClient::send_key(uint32_t hid_usage, bool pressed) {
	gdp::session::InputEnvelope env;
	auto *k = env.mutable_key();
	k->set_hid_usage(hid_usage);
	k->set_state(pressed ? gdp::session::KEY_STATE_PRESSED : gdp::session::KEY_STATE_RELEASED);
	send_input(env);
}

void SessionClient::send_pointer_motion(double dx, double dy, bool absolute) {
	gdp::session::InputEnvelope env;
	auto *m = env.mutable_pointer_motion();
	m->set_dx(dx);
	m->set_dy(dy);
	m->set_absolute(absolute);
	send_input(env);
}

void SessionClient::send_pointer_button(uint32_t button, bool pressed) {
	gdp::session::InputEnvelope env;
	auto *b = env.mutable_pointer_button();
	b->set_button(button);
	b->set_state(pressed ? gdp::session::KEY_STATE_PRESSED : gdp::session::KEY_STATE_RELEASED);
	send_input(env);
}

void SessionClient::send_pointer_axis(double horizontal, double vertical) {
	gdp::session::InputEnvelope env;
	auto *a = env.mutable_pointer_axis();
	a->set_horizontal(horizontal);
	a->set_vertical(vertical);
	send_input(env);
}

void SessionClient::send_touch(uint32_t touch_id, int32_t phase, double x, double y) {
	if (phase < 1 || phase > 4) return;
	gdp::session::InputEnvelope env;
	auto *t = env.mutable_touch();
	t->set_touch_id(touch_id);
	t->set_phase(static_cast<gdp::session::TouchEvent::Phase>(phase));
	t->set_x(x);
	t->set_y(y);
	send_input(env);
}

bool SessionClient::send_microphone(const uint8_t *opus, size_t len) {
	// §10.1, §3.2: only once established, and only under the capability.
	if (!accepted_ || !microphone_ || !conn_ || len == 0) {
		++microphone_dropped_;
		return false;
	}
	std::vector<uint8_t> dgram(1 + gdp::AudioDatagramHeader::kSize + len);
	uint16_t max = conn_->max_datagram_size();
	if (max == 0 || dgram.size() > max) {
		++microphone_dropped_;
		return false;
	}
	gdp::AudioDatagramHeader h;
	h.seq = microphone_seq_++;
	h.pts = static_cast<uint32_t>(gdp::monotonic_us() - session_epoch_us_); // §11, truncated
	h.encode(dgram.data(), gdp::DatagramChannel::kMicrophone);
	std::copy(opus, opus + len, dgram.begin() + 1 + gdp::AudioDatagramHeader::kSize);
	if (!conn_->send_datagram(dgram.data(), dgram.size(), true)) {
		++microphone_dropped_;
		return false;
	}
	++microphone_sent_;
	return true;
}

void SessionClient::send_gamepad_connect(uint32_t slot, const std::string &name) {
	if (!gamepad_ || slot >= gdp::kMaxGamepads) return;
	gdp::session::InputEnvelope env;
	auto *c = env.mutable_gamepad_connect();
	c->set_pad_index(slot);
	c->set_name(name);
	send_input(env);
}

void SessionClient::send_gamepad_state(uint32_t slot, const float *axes, const bool *buttons) {
	if (!gamepad_ || slot >= gdp::kMaxGamepads) return;
	gdp::session::InputEnvelope env;
	auto *g = env.mutable_gamepad();
	g->set_pad_index(slot);
	for (size_t i = 0; i < gdp::kGamepadAxisCount; i++) {
		// §8.5: sticks -1..1, triggers 0..1.
		bool trigger = i >= static_cast<size_t>(gdp::GamepadAxis::kLeftTrigger);
		float v = std::isnan(axes[i]) ? 0.0f : std::clamp(axes[i], trigger ? 0.0f : -1.0f, 1.0f);
		g->add_axes(v);
	}
	for (size_t i = 0; i < gdp::kGamepadButtonCount; i++) g->add_buttons(buttons[i]);
	send_input(env);
}

void SessionClient::send_gamepad_disconnect(uint32_t slot) {
	if (!gamepad_ || slot >= gdp::kMaxGamepads) return;
	gdp::session::InputEnvelope env;
	env.mutable_gamepad_disconnect()->set_pad_index(slot);
	send_input(env);
}

SessionClient::LinkStats SessionClient::link_stats() const {
	LinkStats s;
	if (conn_ && conn_->state() == gdp::ConnectionState::kConnected) {
		s.rtt_us = conn_->rtt_us() + upstream_rtt_us_;
		s.path_mtu = conn_->path_mtu();
		s.max_datagram_size = conn_->max_datagram_size();
	}
	s.upstream_rtt_us = upstream_rtt_us_;
	s.stats_reports_sent = stats_reports_sent_;
	s.frames_delivered = frames_delivered_;
	s.frames_dropped = frames_dropped_;
	s.microphone_sent = microphone_sent_;
	s.microphone_dropped = microphone_dropped_;
	if (!streams_.empty()) s.video = streams_.front().stats.snapshot();
	return s;
}

} // namespace gdpcore

// --- File transfer (§7.12) ---

namespace gdpcore {

uint64_t SessionClient::offer_file(const std::string &name, uint64_t size, int64_t modified_unix_ms) {
	if (!accepted_ || !file_ || !conn_ || !gdp::valid_file_name(name)) return 0;
	std::unique_ptr<gdp::Stream> stream = conn_->open_stream();
	if (!stream) return 0;

	gdp::session::FileOpen file_open;
	auto *offer = file_open.mutable_offer();
	offer->set_name(name);
	offer->set_size(size);
	offer->set_modified_unix_ms(modified_unix_ms);
	gdp::session::StreamOpen open;
	open.set_kind(gdp::kStreamKindFile);
	open.set_params(file_open.SerializeAsString());
	std::vector<uint8_t> frame;
	if (!gdp::encode_frame(open, &frame)) return 0;

	auto owned = std::make_unique<FileTransfer>();
	FileTransfer *t = owned.get();
	t->id = next_file_id_++;
	t->stream = std::move(stream);
	t->size = size;
	t->open_frame_len = frame.size();
	t->offered_us = gdp::monotonic_us();
	t->stream->on_data = [this, t](const uint8_t *data, size_t len) { handle_file_data(t, data, len); };
	// The host always says how it ended before its FIN or a reset; one
	// that doesn't has given up on the file.
	t->stream->on_fin = [this, t] {
		finish_file(t, FileOutcome::kFailed, gdp::session::FILE_ERROR_UNSPECIFIED);
	};
	t->stream->on_reset = [this, t](uint64_t) { finish_file(t, FileOutcome::kCancelled); };
	t->stream->on_acked = [this, t](uint64_t acked) {
		if (t->state == FileTransfer::State::kOffered || !cb_.file_progress) return;
		uint64_t bytes = acked > t->open_frame_len ? acked - t->open_frame_len : 0;
		cb_.file_progress(t->id, std::min(bytes, t->size));
	};
	t->stream->send(frame.data(), frame.size());
	files_[t->id] = std::move(owned);
	return t->id;
}

bool SessionClient::send_file_data(uint64_t id, const uint8_t *data, size_t len) {
	auto it = files_.find(id);
	if (it == files_.end()) return false;
	FileTransfer *t = it->second.get();
	if (t->state != FileTransfer::State::kSending || len > t->size - t->sent) return false;
	if (len == 0) return true;
	t->sent += len;
	bool last = t->sent == t->size;
	t->stream->send(data, len, last);
	if (last) t->state = FileTransfer::State::kSent;
	return true;
}

void SessionClient::cancel_file(uint64_t id) {
	auto it = files_.find(id);
	if (it == files_.end()) return;
	it->second->stream->reset(0);
	files_.erase(it);
}

uint64_t SessionClient::request_file(uint64_t list_id, uint32_t index, uint64_t offset, uint64_t length) {
	if (!accepted_ || !file_ || !conn_) return 0;
	gdp::session::FileOpen file_open;
	auto *request = file_open.mutable_request();
	request->set_list_id(list_id);
	request->set_index(index);
	request->set_offset(offset);
	request->set_length(length);
	FileTransfer *t = open_fetch(file_open, FileTransfer::State::kRequested);
	if (!t) return 0;
	t->want_offset = offset;
	t->want_length = length;
	return t->id;
}

uint64_t SessionClient::request_listing(uint64_t list_id, uint32_t index) {
	if (!accepted_ || !file_clipboard_ || !conn_) return 0;
	gdp::session::FileOpen file_open;
	file_open.mutable_listing()->set_list_id(list_id);
	file_open.mutable_listing()->set_index(index);
	FileTransfer *t = open_fetch(file_open, FileTransfer::State::kListing);
	return t ? t->id : 0;
}

SessionClient::FileTransfer *SessionClient::open_fetch(const gdp::session::FileOpen &file_open,
	FileTransfer::State state) {
	std::unique_ptr<gdp::Stream> stream = conn_->open_stream();
	if (!stream) return nullptr;
	gdp::session::StreamOpen open;
	open.set_kind(gdp::kStreamKindFile);
	open.set_params(file_open.SerializeAsString());
	std::vector<uint8_t> frame;
	if (!gdp::encode_frame(open, &frame)) return nullptr;

	auto owned = std::make_unique<FileTransfer>();
	FileTransfer *t = owned.get();
	t->id = next_file_id_++;
	t->stream = std::move(stream);
	t->state = state;
	t->offered_us = gdp::monotonic_us();
	if (state == FileTransfer::State::kListing) {
		// §7.12: FileReply{listing} frames, each within the list budget.
		t->stream->on_data = [this, t](const uint8_t *data, size_t len) { handle_listing_data(t, data, len); };
		t->stream->on_fin = [this, t] {
			if (t->state == FileTransfer::State::kReceiving) {
				finish_file(t, FileOutcome::kSaved);
			} else {
				finish_file(t, FileOutcome::kFailed, gdp::session::FILE_ERROR_UNSPECIFIED);
			}
		};
	} else {
		t->fetch_reader = std::make_unique<gdp::FrameThenRawReader>(gdp::kMaxFileOpenFrameSize);
		t->stream->on_data = [this, t](const uint8_t *data, size_t len) { handle_fetch_data(t, data, len); };
		t->stream->on_fin = [this, t] { handle_fetch_fin(t); };
	}
	t->stream->on_reset = [this, t](uint64_t) { finish_file(t, FileOutcome::kCancelled); };
	// The request is all this side sends.
	t->stream->send(frame.data(), frame.size(), true);
	files_[t->id] = std::move(owned);
	return t;
}

void SessionClient::handle_listing_data(FileTransfer *t, const uint8_t *data, size_t len) {
	if (local_close_ || closed_reported_) return;
	// Nothing of a listing is the application's to store.
	t->stream->consume(len);
	gdp::session::FileReply reply;
	bool ok = t->reader.feed_and_drain(data, len, &reply, [&] {
		if (local_close_ || closed_reported_) return false;
		if (reply.has_refused() && t->state == FileTransfer::State::kListing) {
			finish_file(t, FileOutcome::kRefused, reply.refused().code());
			return false;
		}
		if (!reply.has_listing()) {
			fail(code(gdp::ErrorCode::kMalformedFrame), "the host's listing came out of order");
			return false;
		}
		t->state = FileTransfer::State::kReceiving;
		std::vector<FileListEntry> files;
		files.reserve(size_t(reply.listing().files_size()));
		for (const auto &f : reply.listing().files()) {
			files.push_back({f.name(), f.size(), f.modified_unix_ms(), f.directory(), 0, f.directory() && f.unlisted()});
		}
		if (cb_.file_listing) cb_.file_listing(t->id, reply.listing().first_index(), files);
		return files_.count(t->id) > 0;
	});
	if (!ok) {
		fail(t->reader.error_code(), t->reader.last_result() == gdp::FrameReader::Result::kTooLarge
				? "the host sent an oversized listing"
				: "the host sent a malformed listing");
	}
}

void SessionClient::consume_file_data(uint64_t id, size_t len) {
	auto it = files_.find(id);
	if (it != files_.end()) it->second->stream->consume(len);
}

void SessionClient::handle_fetch_data(FileTransfer *t, const uint8_t *data, size_t len) {
	if (local_close_ || closed_reported_) return;
	if (t->state == FileTransfer::State::kReceiving) {
		receive_file_bytes(t, data, len);
		return;
	}
	auto state = t->fetch_reader->feed(data, len);
	if (state == gdp::FrameThenRawReader::State::kError) {
		fail(t->fetch_reader->error_code(), "the host sent an oversized file reply");
		return;
	}
	if (state == gdp::FrameThenRawReader::State::kWaiting) {
		t->stream->consume(len); // all of it reply so far
		return;
	}
	std::vector<uint8_t> rest = t->fetch_reader->take_data();
	// The reply's own bytes: nothing for the application to store.
	t->stream->consume(len - rest.size());
	gdp::session::FileReply reply;
	if (!reply.ParseFromString(t->fetch_reader->frame())) {
		fail(code(gdp::ErrorCode::kMalformedFrame), "the host sent a malformed file reply");
		return;
	}
	if (reply.has_refused()) {
		finish_file(t, FileOutcome::kRefused, reply.refused().code());
		return;
	}
	if (!reply.has_sending()) {
		fail(code(gdp::ErrorCode::kMalformedFrame), "the host's file reply came out of order");
		return;
	}
	const auto &sending = reply.sending();
	t->name = sending.name();
	t->size = sending.size();
	uint64_t offset = sending.offset();
	// §7.12: a host that predates ranges sends the whole file from 0;
	// what comes before the asked-for offset is dropped, and anything past
	// the asked-for length is not waited for.
	if (offset > t->want_offset) {
		t->stream->reset(0);
		finish_file(t, FileOutcome::kFailed, gdp::session::FILE_ERROR_UNSPECIFIED);
		return;
	}
	if (offset < t->want_offset) {
		t->skip = std::min(t->want_offset - offset, t->size);
		t->size -= t->skip;
		offset += t->skip;
		if (t->want_length && t->size > t->want_length) {
			t->size = t->want_length;
			t->cut = true;
		}
	}
	t->state = FileTransfer::State::kReceiving;
	uint64_t file_size = sending.file_size() ? sending.file_size() : offset + t->size;
	if (cb_.file_sending) cb_.file_sending(t->id, t->name, t->size, sending.modified_unix_ms(), offset, file_size);
	if (!files_.count(t->id)) return;
	if (t->cut && t->size == 0) {
		t->stream->reset(0);
		std::string name = t->name;
		finish_file(t, FileOutcome::kSaved, 0, name);
		return;
	}
	if (!rest.empty() && files_.count(t->id)) receive_file_bytes(t, rest.data(), rest.size());
}

void SessionClient::receive_file_bytes(FileTransfer *t, const uint8_t *data, size_t len) {
	if (t->skip) {
		size_t n = size_t(std::min<uint64_t>(t->skip, len));
		t->skip -= n;
		t->stream->consume(n); // never the application's
		data += n;
		len -= n;
		if (len == 0) return;
	}
	if (t->cut && len >= t->size - t->received) {
		// All that was asked for: the rest isn't wanted.
		size_t n = size_t(t->size - t->received);
		t->received += n;
		if (cb_.file_data && n) cb_.file_data(t->id, data, n);
		auto it = files_.find(t->id);
		if (it == files_.end()) return;
		t->stream->consume(len - n);
		t->stream->reset(0);
		std::string name = t->name;
		finish_file(t, FileOutcome::kSaved, 0, name);
		return;
	}
	if (len > t->size - t->received) {
		// More than the host said: not this file.
		t->stream->reset(0);
		finish_file(t, FileOutcome::kFailed, gdp::session::FILE_ERROR_SIZE_MISMATCH);
		return;
	}
	t->received += len;
	if (cb_.file_data) cb_.file_data(t->id, data, len);
}

void SessionClient::handle_fetch_fin(FileTransfer *t) {
	if (t->state == FileTransfer::State::kReceiving && t->received == t->size) {
		std::string name = t->name;
		finish_file(t, FileOutcome::kSaved, 0, name);
		return;
	}
	finish_file(t, FileOutcome::kFailed,
		t->state == FileTransfer::State::kReceiving ? gdp::session::FILE_ERROR_SIZE_MISMATCH
													: gdp::session::FILE_ERROR_UNSPECIFIED);
}

void SessionClient::handle_file_data(FileTransfer *t, const uint8_t *data, size_t len) {
	gdp::session::FileReply reply;
	bool ok = t->reader.feed_and_drain(data, len, &reply, [&] { return handle_file_reply(t, reply); });
	if (!ok) {
		// `t` is still there: only a parse failure gets here.
		fail(t->reader.error_code(), t->reader.last_result() == gdp::FrameReader::Result::kTooLarge
				? "the host sent an oversized file reply"
				: "the host sent a malformed file reply");
	}
}

bool SessionClient::handle_file_reply(FileTransfer *t, const gdp::session::FileReply &reply) {
	using R = gdp::session::FileReply;
	using State = FileTransfer::State;
	if (local_close_ || closed_reported_) return false;
	auto out_of_order = [&] {
		fail(code(gdp::ErrorCode::kMalformedFrame), "the host's file reply came out of order");
		return false;
	};
	switch (reply.reply_case()) {
	case R::kAccepted:
		if (t->state != State::kOffered) return out_of_order();
		t->state = State::kSending;
		if (t->size == 0) {
			t->stream->send(nullptr, 0, true);
			t->state = State::kSent;
		}
		if (cb_.file_accepted) cb_.file_accepted(t->id);
		return true;
	case R::kRefused:
		if (t->state != State::kOffered) return out_of_order();
		// §7.12: nothing more but the end of our direction.
		t->stream->send(nullptr, 0, true);
		finish_file(t, FileOutcome::kRefused, reply.refused().code());
		return false;
	case R::kSaved:
		if (t->state != State::kSent) return out_of_order();
		finish_file(t, FileOutcome::kSaved, 0, reply.saved().name(), reply.saved().directory());
		return false;
	case R::kFailed:
		if (t->state == State::kOffered) return out_of_order();
		finish_file(t, FileOutcome::kFailed, reply.failed().code());
		return false;
	default:
		// Unset, or a case from a newer host: ignored (§3.1).
		return true;
	}
}

void SessionClient::finish_file(FileTransfer *t, FileOutcome outcome, int32_t error, const std::string &saved_name,
	const std::string &saved_directory) {
	uint64_t id = t->id;
	// Dropping the stream: let go gracefully once our side has finished
	// (the host's last frames still arrive), reset otherwise.
	files_.erase(id);
	if (cb_.file_finished) cb_.file_finished(id, outcome, error, saved_name, saved_directory);
}

void SessionClient::expire_file_offers() {
	uint64_t timeout_us =
		uint64_t(config_.file_reply_timeout_ms ? config_.file_reply_timeout_ms : gdp::kFileReplyTimeoutMs) * 1000;
	uint64_t now = gdp::monotonic_us();
	std::vector<FileTransfer *> expired;
	for (auto &[id, t] : files_) {
		bool waiting = t->state == FileTransfer::State::kOffered || t->state == FileTransfer::State::kRequested ||
			t->state == FileTransfer::State::kListing;
		if (waiting && now - t->offered_us > timeout_us) expired.push_back(t.get());
	}
	for (FileTransfer *t : expired) {
		t->stream->reset(0);
		finish_file(t, FileOutcome::kTimedOut);
	}
}

// --- This side's files, read by the host (§7.12, file-clipboard) ---

namespace {

// The lists the host may read from, the latest included, and how long one
// stays after it was replaced or last read (§7.12's reference host keeps
// as many, as long).
constexpr size_t kKeptLists = 5;
constexpr uint64_t kKeptListUs = 10ull * 60 * 1000 * 1000;

} // namespace

void SessionClient::set_copied_files(const std::vector<std::string> &paths) {
	if (!accepted_ || !file_clipboard_) return;
	uint64_t generation = ++copied_generation_;
	uint64_t list_id = next_list_id_++;
	auto send = [this, list_id](gdp::LocalFileList list) {
		uint64_t now = gdp::monotonic_us();
		for (auto &[id, kept] : copied_lists_) {
			if (!kept.replaced_us) kept.replaced_us = now;
		}
		gdp::session::ControlEnvelope env;
		*env.mutable_file_list() = list.listing();
		env.mutable_file_list()->set_list_id(list_id);
		nfc_names(env.mutable_file_list());
		if (list.size()) copied_lists_[list_id] = CopiedList{std::move(list), 0, now};
		forget_copied_lists();
		send_control(env);
	};
	if (paths.empty()) {
		send(gdp::LocalFileList());
		return;
	}
	// Reading the folders may take a while: off the session's thread.
	worker_.run<std::shared_ptr<gdp::LocalFileList>>(
		[paths, list_id] {
			return std::make_shared<gdp::LocalFileList>(gdp::LocalFileList::build(list_id, paths, true));
		},
		[this, generation, send](std::shared_ptr<gdp::LocalFileList> list) {
			if (generation != copied_generation_ || !accepted_) return; // copied over, or gone
			send(std::move(*list));
		});
}

void SessionClient::forget_copied_lists() {
	uint64_t now = gdp::monotonic_us();
	for (auto it = copied_lists_.begin(); it != copied_lists_.end();) {
		const CopiedList &kept = it->second;
		bool stale = kept.replaced_us && now - std::max(kept.replaced_us, kept.read_us) > kKeptListUs;
		it = stale ? copied_lists_.erase(it) : std::next(it);
	}
	while (copied_lists_.size() > kKeptLists) {
		// The one read from least recently goes, never the latest.
		auto oldest = copied_lists_.end();
		for (auto it = copied_lists_.begin(); it != copied_lists_.end(); ++it) {
			if (it->second.replaced_us && (oldest == copied_lists_.end() || it->second.read_us < oldest->second.read_us)) {
				oldest = it;
			}
		}
		if (oldest == copied_lists_.end()) break;
		copied_lists_.erase(oldest);
	}
}

void SessionClient::handle_fetch(const gdp::session::FileFetch &fetch) {
	// §6.7: nothing of a capability not in effect.
	if (!file_clipboard_) return;
	uint64_t fetch_id = fetch.fetch_id();
	auto it = copied_lists_.find(fetch.list_id());
	if (fetch.share_id() || it == copied_lists_.end() || fetch.index() >= it->second.list.size()) {
		answer_refused(fetch_id, gdp::session::FILE_ERROR_GONE);
		return;
	}
	CopiedList &kept = it->second;
	kept.read_us = gdp::monotonic_us();
	uint32_t index = fetch.index();
	uint64_t list_id = fetch.list_id();
	std::string path = kept.list.path(index);
	// Only what was copied may be reached through a symbolic link (§7.12).
	bool top = kept.list.is_top_level(index);
	if (fetch.listing()) {
		if (!kept.list.is_directory(index)) {
			answer_refused(fetch_id, gdp::session::FILE_ERROR_GONE);
			return;
		}
		if (kept.list.listed(index)) {
			std::vector<gdp::session::FileListing> frames;
			kept.list.list_folder(index, &frames);
			answer_listing(fetch_id, std::move(frames));
			return;
		}
		using Entries = std::optional<std::vector<gdp::LocalEntry>>;
		worker_.run<Entries>(
			[path, top]() -> Entries {
				if (!top && !is_plain_folder(path)) return std::nullopt;
				return gdp::read_local_folder(path);
			},
			[this, fetch_id, list_id, index](Entries entries) {
				if (!accepted_) return;
				auto it = copied_lists_.find(list_id);
				std::vector<gdp::session::FileListing> frames;
				if (!entries || it == copied_lists_.end() || !it->second.list.add_folder(index, *entries) ||
					!it->second.list.list_folder(index, &frames)) {
					answer_refused(fetch_id, gdp::session::FILE_ERROR_GONE);
					return;
				}
				answer_listing(fetch_id, std::move(frames));
			});
		return;
	}
	if (kept.list.is_directory(index)) {
		answer_refused(fetch_id, gdp::session::FILE_ERROR_GONE);
		return;
	}
	std::string name = kept.list.listing().files(int(index)).name();
	uint64_t offset = fetch.offset(), length = fetch.length();
	worker_.run<OpenedFile>([path, top] { return open_regular(path, top); },
		[this, fetch_id, offset, length, name](OpenedFile file) {
			if (!accepted_) {
				if (file.fd >= 0) ::close(file.fd);
				return;
			}
			if (file.error) {
				answer_refused(fetch_id, file.error);
				return;
			}
			answer_bytes(fetch_id, file.fd, file.size, file.modified_unix_ms, offset, length, name);
		});
}

std::unique_ptr<gdp::Stream> SessionClient::open_answer(uint64_t fetch_id, size_t *open_frame_len) {
	if (!accepted_ || !conn_) return nullptr;
	std::unique_ptr<gdp::Stream> stream = conn_->open_stream();
	if (!stream) return nullptr;
	gdp::session::FileOpen file_open;
	file_open.mutable_answer()->set_fetch_id(fetch_id);
	gdp::session::StreamOpen open;
	open.set_kind(gdp::kStreamKindFile);
	open.set_params(file_open.SerializeAsString());
	std::vector<uint8_t> frame;
	if (!gdp::encode_frame(open, &frame)) return nullptr;
	stream->send(frame.data(), frame.size());
	if (open_frame_len) *open_frame_len = frame.size();
	return stream;
}

void SessionClient::answer_refused(uint64_t fetch_id, int32_t code) {
	std::unique_ptr<gdp::Stream> stream = open_answer(fetch_id);
	if (!stream) return;
	gdp::session::FileReply reply;
	reply.mutable_refused()->set_code(static_cast<gdp::session::FileErrorCode>(code));
	stream->send_message(reply);
	// Let go gracefully: the FIN goes out after the reply.
	stream->send(nullptr, 0, true);
}

void SessionClient::answer_listing(uint64_t fetch_id, std::vector<gdp::session::FileListing> frames) {
	std::unique_ptr<gdp::Stream> stream = open_answer(fetch_id);
	if (!stream) return;
	gdp::session::FileReply reply;
	for (auto &frame : frames) {
		nfc_names(&frame);
		*reply.mutable_listing() = std::move(frame);
		stream->send_message(reply);
	}
	stream->send(nullptr, 0, true);
}

void SessionClient::answer_bytes(uint64_t fetch_id, int fd, uint64_t file_size, int64_t modified_unix_ms,
	uint64_t offset, uint64_t length, const std::string &name) {
	// §7.12: from `offset` up to `offset + length`, cut short at the end; at
	// or past the end, nothing, which is not an error.
	uint64_t start = std::min(offset, file_size);
	uint64_t size = file_size - start;
	if (length) size = std::min(size, length);
	size_t open_len = 0;
	std::unique_ptr<gdp::Stream> stream = open_answer(fetch_id, &open_len);
	if (!stream) {
		::close(fd);
		return;
	}
	gdp::session::FileReply reply;
	auto *sending = reply.mutable_sending();
	sending->set_name(nfc(name));
	sending->set_size(size);
	sending->set_modified_unix_ms(modified_unix_ms);
	sending->set_offset(start);
	sending->set_file_size(file_size);
	std::vector<uint8_t> frame;
	if (!gdp::encode_frame(reply, &frame)) {
		::close(fd);
		stream->reset(0);
		return;
	}
	stream->send(frame.data(), frame.size(), size == 0);
	if (size == 0 || !cb_.file_serve) {
		::close(fd);
		if (size) stream->reset(0);
		return;
	}
	auto owned = std::make_unique<FileTransfer>();
	FileTransfer *t = owned.get();
	t->id = next_file_id_++;
	t->stream = std::move(stream);
	t->state = FileTransfer::State::kSending;
	t->answer = true;
	t->size = size;
	t->name = name;
	t->open_frame_len = open_len + frame.size();
	t->offered_us = gdp::monotonic_us();
	// The host sends nothing on it; it resets a stream it no longer wants.
	t->stream->on_data = [t](const uint8_t *, size_t len) { t->stream->consume(len); };
	t->stream->on_fin = [] {};
	t->stream->on_reset = [this, t](uint64_t) { finish_file(t, FileOutcome::kCancelled); };
	t->stream->on_acked = [this, t](uint64_t acked) {
		uint64_t bytes = acked > t->open_frame_len ? std::min(acked - t->open_frame_len, t->size) : 0;
		if (cb_.file_progress) cb_.file_progress(t->id, bytes);
		if (bytes == t->size && t->state == FileTransfer::State::kSent && files_.count(t->id)) {
			std::string served = t->name;
			finish_file(t, FileOutcome::kSaved, 0, served);
		}
	};
	uint64_t id = t->id;
	files_[id] = std::move(owned);
	cb_.file_serve(id, fd, start, size);
}

} // namespace gdpcore
