#include "session_client.hpp"

#include "gdp/cert_fingerprint.hpp"
#include "gdp/clipboard.hpp"
#include "gdp/clock.hpp"
#include "gdp/datagram.hpp"
#include "gdp/error_codes.hpp"
#include "gdp/framing.hpp"
#include "gdp/gamepad.hpp"
#include "gdp/version.hpp"
#include "session.pb.h"

#include <algorithm>
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
	accepted_ = true;
	// §11: our session clock starts now.
	session_epoch_us_ = gdp::monotonic_us();
	for (auto &st : streams_) st.stats.start(session_epoch_us_);
	if (cb_.accepted) cb_.accepted(info);

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
