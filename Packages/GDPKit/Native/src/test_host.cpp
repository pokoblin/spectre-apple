#include "test_host.hpp"

#include "server_loop.hpp"

#include "gdp/clock.hpp"
#include "gdp/datagram.hpp"
#include "gdp/error_codes.hpp"
#include "gdp/framing.hpp"
#include "gdp/negotiation.hpp"
#include "gdp/transport.hpp"
#include "gdp/version.hpp"
#include "session.pb.h"

#include <algorithm>
#include <list>

namespace gdpcore {

namespace {

constexpr size_t kPreAuthFrameSize = 16 * 1024; // §6.3

uint64_t code(gdp::ErrorCode c) {
	return static_cast<uint64_t>(c);
}

} // namespace

struct TestHost::Impl {
	struct Peer {
		std::unique_ptr<gdp::Connection> conn;
		gdp::Stream *control = nullptr;
		gdp::FrameReader control_reader;
		gdp::FrameReader input_reader;
		bool hello_seen = false;
		bool accepted = false;
		bool microphone = false; // negotiated (§10.1)
		bool closing = false;
		uint64_t close_at_us = 0; // a delayed close (after SessionReject)
		uint64_t close_code = 0;
	};

	Config cfg;
	// Declared before `peers`, so the transport outlives the connections;
	// ~Impl stops the thread before anything is destroyed.
	ServerLoop loop;
	std::list<std::unique_ptr<Peer>> peers;
	Peer *viewer = nullptr;

	mutable std::mutex mu; // guards `obs`, `microphone_log` and `keyframe_wanted`
	Observed obs;
	std::vector<MicrophonePacket> microphone_log;
	std::optional<MicrophonePacket> latest_microphone;
	bool keyframe_wanted = false;

	// Loop thread only.
	uint64_t epoch_us = 0;
	uint32_t next_frame_id = 0;
	uint16_t next_audio_seq = 0;
	uint32_t width = 0;
	uint32_t height = 0;

	~Impl() { loop.stop(); }

	void post(std::function<void()> fn) { loop.post(std::move(fn)); }

	void tick() {
		uint64_t now = gdp::monotonic_us();
		for (auto &p : peers) {
			if (p->close_at_us && now >= p->close_at_us) {
				p->close_at_us = 0;
				close_peer(*p, p->close_code);
			}
		}
	}

	void close_peer(Peer &p, uint64_t c) {
		if (p.closing) return;
		p.closing = true;
		p.accepted = false;
		if (&p == viewer) viewer = nullptr;
		p.conn->close(c);
		std::lock_guard lock(mu);
		obs.closed = true;
		obs.close_code = c;
	}

	void on_new_connection(std::unique_ptr<gdp::Connection> conn) {
		auto peer = std::make_unique<Peer>();
		Peer *p = peer.get();
		p->conn = std::move(conn);
		p->control_reader.set_max_frame_size(kPreAuthFrameSize);
		p->conn->on_control_stream = [this, p](gdp::Stream *s) {
			p->control = s;
			s->on_data = [this, p](const uint8_t *data, size_t len) { on_control(*p, data, len); };
		};
		p->conn->on_input_stream = [this, p](gdp::Stream *s) {
			s->on_data = [this, p](const uint8_t *data, size_t len) { on_input(*p, data, len); };
		};
		p->conn->on_datagram = [this, p](const uint8_t *data, size_t len, uint64_t) { on_datagram(*p, data, len); };
		p->conn->on_state_changed = [this, p](gdp::ConnectionState st) {
			if (st != gdp::ConnectionState::kShutdown || p != viewer) return;
			viewer = nullptr;
			std::lock_guard lock(mu);
			obs.viewer_closed = true;
			obs.viewer_close_code = p->conn->shutdown_error_code();
			obs.viewer_close_reason = p->conn->shutdown_reason();
		};
		peers.push_back(std::move(peer));
		std::lock_guard lock(mu);
		obs.connected = true;
	}

	void on_datagram(Peer &p, const uint8_t *data, size_t len) {
		auto channel = gdp::peek_channel(data, len);
		if (!channel || *channel != gdp::DatagramChannel::kMicrophone) return;
		gdp::AudioDatagramHeader h;
		const uint8_t *payload = nullptr;
		size_t plen = 0;
		bool ok = gdp::AudioDatagramHeader::decode(data, len, &h, &payload, &plen, gdp::DatagramChannel::kMicrophone);
		std::lock_guard lock(mu);
		// §3.2, §10.1: only from the authenticated viewer, under the capability.
		if (!ok || !p.accepted || !p.microphone || &p != viewer) {
			obs.microphone_dropped++;
			return;
		}
		obs.microphone_packets++;
		obs.microphone_bytes += len;
		MicrophonePacket packet{h.seq, h.pts, std::vector<uint8_t>(payload, payload + plen)};
		if (microphone_log.size() < TestHost::kMaxMicrophoneLog) microphone_log.push_back(packet);
		latest_microphone = std::move(packet);
	}

	void send(Peer &p, const gdp::session::ControlEnvelope &env) {
		if (p.control) p.control->send_message(env);
	}

	void on_control(Peer &p, const uint8_t *data, size_t len) {
		gdp::session::ControlEnvelope env;
		bool ok = p.control_reader.feed_and_drain(data, len, &env, [&] {
			if (p.closing) return false;
			if (!p.hello_seen) {
				// §6.3: the first frame must be a SessionHello; any failure is AUTH_FAILED.
				if (!env.has_hello()) {
					close_peer(p, code(gdp::ErrorCode::kAuthFailed));
					return false;
				}
				p.hello_seen = true;
				on_hello(p, env.hello());
				return !p.closing;
			}
			if (p.accepted) on_established_message(p, env);
			return true;
		});
		if (!ok) {
			close_peer(p, p.accepted ? p.control_reader.error_code() : code(gdp::ErrorCode::kAuthFailed));
		}
	}

	void on_hello(Peer &p, const gdp::session::SessionHello &hello) {
		{
			std::lock_guard lock(mu);
			obs.hello_received = true;
			obs.token = hello.token();
			obs.codecs.assign(hello.codecs().begin(), hello.codecs().end());
			obs.capabilities.assign(hello.capabilities().begin(), hello.capabilities().end());
			obs.decoders.assign(hello.decoders().begin(), hello.decoders().end());
			obs.take_over = hello.take_over();
			obs.via_gateway = hello.via_gateway();
			obs.network_profile = hello.network_profile();
			if (hello.displays_size() > 0) {
				obs.requested_width = hello.displays(0).width();
				obs.requested_height = hello.displays(0).height();
			}
		}
		if (hello.token() != cfg.token) return close_peer(p, code(gdp::ErrorCode::kAuthFailed));
		if (cfg.refuse_code) return close_peer(p, cfg.refuse_code);
		if (!cfg.reject_reason.empty()) {
			gdp::session::ControlEnvelope env;
			env.mutable_reject()->set_reason(cfg.reject_reason);
			send(p, env);
			p.close_code = code(gdp::ErrorCode::kAuthFailed);
			p.close_at_us = gdp::monotonic_us() + 200'000;
			return;
		}
		// §6.4: one viewer.
		if (viewer && viewer != &p) {
			if (!hello.take_over()) return close_peer(p, code(gdp::ErrorCode::kAlreadyConnected));
			close_peer(*viewer, code(gdp::ErrorCode::kTakenOver));
		}

		std::vector<std::string> offered(hello.codecs().begin(), hello.codecs().end());
		std::string chosen = cfg.force_codec;
		if (chosen.empty()) {
			auto common = gdp::common_video_codecs(offered, cfg.codecs);
			if (common.empty()) return close_peer(p, code(gdp::ErrorCode::kNoCommonCodec));
			chosen = common.front();
		}

		if (cfg.ping_before_accept) {
			gdp::session::ControlEnvelope ping;
			ping.mutable_ping()->set_nonce(99);
			send(p, ping);
		}

		width = cfg.width;
		height = cfg.height;
		gdp::session::ControlEnvelope env;
		auto *accept = env.mutable_accept();
		fill_output(accept->add_outputs());
		accept->set_codec(chosen);
		accept->set_bitrate_ceiling_bps(50'000'000);
		if (cfg.audio) {
			auto *a = accept->mutable_audio();
			a->set_sample_rate_hz(cfg.audio_sample_rate_hz);
			a->set_channels(cfg.audio_channels);
			a->set_frame_ms(cfg.audio_frame_ms);
			a->set_codec(cfg.audio_codec);
		}
		std::vector<std::string> offered_caps(hello.capabilities().begin(), hello.capabilities().end());
		p.microphone = false;
		for (const auto &c : gdp::negotiate_capabilities(offered_caps, cfg.capabilities)) {
			accept->add_capabilities(c);
			if (c == "microphone") p.microphone = true;
		}
		if (p.microphone) {
			auto *m = accept->mutable_microphone();
			m->set_sample_rate_hz(cfg.microphone_sample_rate_hz);
			m->set_channels(cfg.microphone_channels);
			m->set_frame_ms(cfg.microphone_frame_ms);
			m->set_codec(cfg.microphone_codec);
		}
		accept->set_network_profile(hello.network_profile() == gdp::session::NETWORK_PROFILE_AUTO
				? gdp::session::NETWORK_PROFILE_LAN
				: hello.network_profile());
		accept->set_via_gateway(hello.via_gateway());
		accept->set_encoder("test");
		accept->set_host_user("tester");
		accept->set_host_name("loopback");
		send(p, env);

		p.accepted = true;
		p.control_reader.set_max_frame_size(gdp::kMaxFrameSize);
		viewer = &p;
		epoch_us = gdp::monotonic_us(); // §11
		next_frame_id = cfg.first_frame_id;
		next_audio_seq = 0; // §10

		// §6.5: the current cursor right after accepting.
		gdp::session::ControlEnvelope cursor;
		auto *c = cursor.mutable_cursor_shape();
		c->set_width(2);
		c->set_height(2);
		c->set_argb8888(std::string(16, '\xff'));
		send(p, cursor);

		std::lock_guard lock(mu);
		obs.accepted = true;
		obs.accepted_codec = chosen;
		obs.next_frame_id = next_frame_id;
		keyframe_wanted = true; // §6.5: a keyframe right after accepting
	}

	void fill_output(gdp::session::OutputDescriptor *o) const {
		o->set_stream_id(0);
		o->mutable_display()->set_width(width);
		o->mutable_display()->set_height(height);
		o->mutable_display()->set_refresh_mhz(60000);
		o->mutable_display()->set_scale(1.0);
		auto *color = o->mutable_color();
		color->set_matrix(gdp::session::COLOR_MATRIX_BT601);
		color->set_range(gdp::session::COLOR_RANGE_LIMITED);
		color->set_primaries(gdp::session::COLOR_PRIMARIES_BT709);
		color->set_transfer(gdp::session::COLOR_TRANSFER_SRGB);
		color->set_bit_depth(8);
		color->set_chroma(gdp::session::CHROMA_420);
	}

	void on_established_message(Peer &p, const gdp::session::ControlEnvelope &env) {
		using E = gdp::session::ControlEnvelope;
		switch (env.msg_case()) {
		case E::kStats: {
			const auto &r = env.stats();
			std::lock_guard lock(mu);
			obs.stats_reports++;
			Observed::Stats s;
			s.rtt_us = r.rtt_us();
			if (r.streams_size() > 0) {
				const auto &st = r.streams(0);
				s.has_stream = true;
				s.stream_id = st.stream_id();
				s.highest_frame_id_acked = st.highest_frame_id_acked();
				s.loss_bitmap = st.loss_bitmap();
				s.decode_us = st.decode_us();
				s.present_us = st.present_us();
				s.interval_us = st.interval_us();
				s.bytes_received = st.bytes_received();
				s.delay_min_us = st.delay_min_us();
				s.delay_avg_us = st.delay_avg_us();
				s.delay_samples = st.delay_samples();
				s.trains = static_cast<uint32_t>(st.trains_size());
				if (st.trains_size() > 0) {
					s.train_datagrams = st.trains(st.trains_size() - 1).datagrams();
					s.train_bytes = st.trains(st.trains_size() - 1).bytes();
				}
				obs.bytes_reported += st.bytes_received();
				for (int i = 0; i < 64; i++) {
					if (!(st.loss_bitmap() >> i & 1)) continue;
					uint32_t id = st.highest_frame_id_acked() - static_cast<uint32_t>(i);
					if (std::find(obs.lost_frame_ids.begin(), obs.lost_frame_ids.end(), id) == obs.lost_frame_ids.end()) {
						obs.lost_frame_ids.push_back(id);
						keyframe_wanted = true; // the reference host repairs a new loss with a keyframe
					}
				}
			}
			obs.last_stats = s;
			break;
		}
		case E::kPing: {
			gdp::session::ControlEnvelope pong;
			pong.mutable_pong()->set_nonce(env.ping().nonce());
			send(p, pong);
			break;
		}
		case E::kPong: {
			std::lock_guard lock(mu);
			obs.pongs++;
			obs.last_pong_nonce = env.pong().nonce();
			break;
		}
		case E::kKeyframeRequest: {
			std::lock_guard lock(mu);
			obs.keyframe_requests++;
			keyframe_wanted = true;
			break;
		}
		case E::kResolutionChange: {
			uint32_t w = env.resolution_change().display().width();
			uint32_t h = env.resolution_change().display().height();
			{
				std::lock_guard lock(mu);
				obs.resolution_requests.emplace_back(w, h);
			}
			// §7.2: refuse odd sizes and sizes outside 320-8192; answer either way.
			if (w % 2 == 0 && h % 2 == 0 && w >= 320 && h >= 320 && w <= 8192 && h <= 8192) {
				width = w;
				height = h;
			}
			send_displays_changed_now();
			break;
		}
		case E::kLogoutRequest: {
			{
				std::lock_guard lock(mu);
				obs.logout_requested = true;
			}
			close_peer(p, code(gdp::ErrorCode::kSessionEnded)); // §7.10
			break;
		}
		case E::kDiagnosticsReport: {
			std::lock_guard lock(mu);
			obs.diagnostics_report = env.diagnostics_report().text();
			break;
		}
		default:
			break;
		}
	}

	void on_input(Peer &p, const uint8_t *data, size_t len) {
		gdp::session::InputEnvelope env;
		bool moved_relative = false;
		p.input_reader.feed_and_drain(data, len, &env, [&] {
			std::lock_guard lock(mu);
			if (!p.accepted) {
				obs.input_before_accept = true; // §8.1: must not act on it
				return true;
			}
			TestHost::InputEvent ev{};
			switch (env.event_case()) {
			case gdp::session::InputEnvelope::kKey:
				obs.keys.emplace_back(env.key().hid_usage(), env.key().state() == gdp::session::KEY_STATE_PRESSED);
				ev.kind = TestHost::InputEvent::Key;
				ev.code = env.key().hid_usage();
				ev.pressed = env.key().state() == gdp::session::KEY_STATE_PRESSED;
				break;
			case gdp::session::InputEnvelope::kPointerMotion: {
				const auto &m = env.pointer_motion();
				obs.pointer_motions++;
				obs.last_motion_x = m.dx();
				obs.last_motion_y = m.dy();
				obs.last_motion_absolute = m.absolute();
				ev.kind = TestHost::InputEvent::Motion;
				ev.x = m.dx();
				ev.y = m.dy();
				ev.absolute = m.absolute();
				if (cfg.simulate_pointer) {
					double x = m.absolute() ? m.dx() : obs.pointer_x + m.dx() / std::max<uint32_t>(width, 1);
					double y = m.absolute() ? m.dy() : obs.pointer_y + m.dy() / std::max<uint32_t>(height, 1);
					x = std::clamp(x, 0.0, 1.0);
					y = std::clamp(y, 0.0, 1.0);
					if (!m.absolute() && (x != obs.pointer_x || y != obs.pointer_y)) moved_relative = true;
					obs.pointer_x = x;
					obs.pointer_y = y;
				}
				break;
			}
			case gdp::session::InputEnvelope::kPointerButton:
				obs.buttons.emplace_back(env.pointer_button().button(),
					env.pointer_button().state() == gdp::session::KEY_STATE_PRESSED);
				ev.kind = TestHost::InputEvent::Button;
				ev.code = env.pointer_button().button();
				ev.pressed = env.pointer_button().state() == gdp::session::KEY_STATE_PRESSED;
				break;
			case gdp::session::InputEnvelope::kPointerAxis:
				obs.axis_vertical_sum += env.pointer_axis().vertical();
				obs.axis_horizontal_sum += env.pointer_axis().horizontal();
				ev.kind = TestHost::InputEvent::Axis;
				ev.x = env.pointer_axis().horizontal();
				ev.y = env.pointer_axis().vertical();
				break;
			case gdp::session::InputEnvelope::kTouch:
				obs.touches++;
				ev.kind = TestHost::InputEvent::Touch;
				ev.code = env.touch().touch_id();
				ev.phase = env.touch().phase();
				ev.x = env.touch().x();
				ev.y = env.touch().y();
				break;
			default:
				return true;
			}
			if (obs.inputs.size() < TestHost::kMaxInputLog) obs.inputs.push_back(ev);
			return true;
		});
		// §7.4: at most one CursorPosition per batch, only when it changed.
		if (moved_relative && viewer == &p) {
			double x, y;
			{
				std::lock_guard lock(mu);
				x = obs.pointer_x;
				y = obs.pointer_y;
				obs.cursor_positions_sent++;
			}
			gdp::session::ControlEnvelope env;
			env.mutable_cursor_position()->set_x(x);
			env.mutable_cursor_position()->set_y(y);
			send(p, env);
		}
	}

	void send_displays_changed_now() {
		if (!viewer) return;
		gdp::session::ControlEnvelope env;
		fill_output(env.mutable_displays_changed()->add_outputs());
		send(*viewer, env);
	}

	void send_video(const std::vector<uint8_t> &data, bool keyframe, const std::vector<uint16_t> &drop,
		size_t max_payload) {
		if (!viewer) return;
		gdp::VideoDatagramHeader hdr;
		hdr.stream_id = 0;
		hdr.frame_id = next_frame_id++;
		hdr.flags = keyframe ? gdp::VideoDatagramHeader::kFlagKeyframe : 0;
		hdr.pts = static_cast<uint32_t>(gdp::monotonic_us() - epoch_us);
		hdr.host_latency = gdp::VideoDatagramHeader::host_latency_from_us(500);
		size_t payload = max_payload ? max_payload : gdp::slice_payload_for(viewer->conn->max_datagram_size());
		uint16_t idx = 0;
		gdp::slice_video_frame(hdr, data.data(), data.size(), payload, [&](const uint8_t *dgram, size_t len) {
			bool dropped = std::find(drop.begin(), drop.end(), idx++) != drop.end();
			return dropped || viewer->conn->send_datagram(dgram, len);
		});
		std::lock_guard lock(mu);
		obs.frames_sent++;
		obs.next_frame_id = next_frame_id;
		obs.max_datagram_size = viewer->conn->max_datagram_size();
	}
};

TestHost::TestHost() : impl_(std::make_unique<Impl>()) {}

TestHost::~TestHost() = default;

bool TestHost::start(const Config &config, std::string *error) {
	Impl &m = *impl_;
	m.cfg = config;
	if (!m.loop.start(
			config.scratch_dir, [&m](std::unique_ptr<gdp::Connection> conn) { m.on_new_connection(std::move(conn)); },
			[&m] { m.tick(); }, error)) {
		return false;
	}
	port_ = m.loop.port();
	cert_sha256_ = m.loop.cert_sha256();
	return true;
}

void TestHost::send_video_frame(std::vector<uint8_t> data, bool keyframe, std::vector<uint16_t> drop_slices,
	size_t max_payload) {
	impl_->post([m = impl_.get(), data = std::move(data), keyframe, drop = std::move(drop_slices), max_payload] {
		m->send_video(data, keyframe, drop, max_payload);
	});
}

void TestHost::send_audio_packet(uint16_t seq, uint32_t pts, std::vector<uint8_t> opus) {
	impl_->post([m = impl_.get(), seq, pts, opus = std::move(opus)] {
		if (!m->viewer) return;
		std::vector<uint8_t> dgram(1 + gdp::AudioDatagramHeader::kSize + opus.size());
		gdp::AudioDatagramHeader h;
		h.seq = seq;
		h.pts = pts;
		h.encode(dgram.data());
		std::copy(opus.begin(), opus.end(), dgram.begin() + 1 + gdp::AudioDatagramHeader::kSize);
		m->viewer->conn->send_datagram(dgram.data(), dgram.size(), true);
	});
}

void TestHost::send_audio(std::vector<uint8_t> opus) {
	impl_->post([m = impl_.get(), opus = std::move(opus)] {
		if (!m->viewer) return;
		std::vector<uint8_t> dgram(1 + gdp::AudioDatagramHeader::kSize + opus.size());
		gdp::AudioDatagramHeader h;
		h.seq = m->next_audio_seq++;
		h.pts = static_cast<uint32_t>(gdp::monotonic_us() - m->epoch_us);
		h.encode(dgram.data());
		std::copy(opus.begin(), opus.end(), dgram.begin() + 1 + gdp::AudioDatagramHeader::kSize);
		m->viewer->conn->send_datagram(dgram.data(), dgram.size(), true);
	});
}

void TestHost::send_ping(uint64_t nonce) {
	impl_->post([m = impl_.get(), nonce] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_ping()->set_nonce(nonce);
		m->send(*m->viewer, env);
	});
}

void TestHost::send_cursor_shape(uint32_t w, uint32_t h, uint32_t hot_x, uint32_t hot_y, std::vector<uint8_t> argb) {
	impl_->post([m = impl_.get(), w, h, hot_x, hot_y, argb = std::move(argb)] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		auto *c = env.mutable_cursor_shape();
		c->set_width(w);
		c->set_height(h);
		c->set_hotspot_x(hot_x);
		c->set_hotspot_y(hot_y);
		c->set_argb8888(std::string(argb.begin(), argb.end()));
		m->send(*m->viewer, env);
	});
}

void TestHost::send_cursor_position(double x, double y) {
	impl_->post([m = impl_.get(), x, y] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_cursor_position()->set_x(x);
		env.mutable_cursor_position()->set_y(y);
		m->send(*m->viewer, env);
	});
}

void TestHost::send_displays_changed(uint32_t w, uint32_t h) {
	impl_->post([m = impl_.get(), w, h] {
		m->width = w;
		m->height = h;
		m->send_displays_changed_now();
	});
}

void TestHost::send_network_profile(int32_t profile) {
	impl_->post([m = impl_.get(), profile] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_network_profile_changed()->set_profile(static_cast<gdp::session::NetworkProfile>(profile));
		m->send(*m->viewer, env);
	});
}

void TestHost::send_gateway_path(uint32_t upstream_rtt_us) {
	impl_->post([m = impl_.get(), upstream_rtt_us] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_gateway_path()->set_upstream_rtt_us(upstream_rtt_us);
		m->send(*m->viewer, env);
	});
}

void TestHost::send_diagnostics_request() {
	impl_->post([m = impl_.get()] {
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_diagnostics_request();
		m->send(*m->viewer, env);
	});
}

void TestHost::close(uint64_t c) {
	impl_->post([m = impl_.get(), c] {
		if (m->viewer) m->close_peer(*m->viewer, c);
	});
}

bool TestHost::take_keyframe_wanted() {
	std::lock_guard lock(impl_->mu);
	bool wanted = impl_->keyframe_wanted;
	impl_->keyframe_wanted = false;
	return wanted;
}

TestHost::Observed TestHost::observed() const {
	std::lock_guard lock(impl_->mu);
	return impl_->obs;
}

bool TestHost::latest_microphone_packet(MicrophonePacket *out) const {
	std::lock_guard lock(impl_->mu);
	if (!impl_->latest_microphone) return false;
	*out = *impl_->latest_microphone;
	return true;
}

bool TestHost::microphone_packet(size_t index, MicrophonePacket *out) const {
	std::lock_guard lock(impl_->mu);
	if (index >= impl_->microphone_log.size()) return false;
	*out = impl_->microphone_log[index];
	return true;
}

} // namespace gdpcore
