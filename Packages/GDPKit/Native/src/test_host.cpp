#include "test_host.hpp"

#include "server_loop.hpp"

#include "gdp/clipboard.hpp"
#include "gdp/clock.hpp"
#include "gdp/datagram.hpp"
#include "gdp/error_codes.hpp"
#include "gdp/file_list.hpp"
#include "gdp/file_transfer.hpp"
#include "gdp/framing.hpp"
#include "gdp/negotiation.hpp"
#include "gdp/transport.hpp"
#include "gdp/version.hpp"
#include "session.pb.h"

#include <algorithm>
#include <cerrno>
#include <list>
#include <map>
#include <set>

#include <fcntl.h>
#include <fstream>
#include <iterator>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

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
		bool clipboard = false; // `clipboard` in effect
		bool file = false;      // `file` in effect
		bool file_clipboard = false; // `file-clipboard` in effect (with `file` and `clipboard`)
		bool file_share = false;     // `file-share` in effect (with `file`)
		bool refine = false;    // `refine` in effect: every payload a container (§9.5)
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

	// §7.12: file streams from the viewer, until each is answered.
	struct Incoming {
		Peer *peer = nullptr;
		std::unique_ptr<gdp::Stream> stream;
		gdp::FileStreamReader reader;
		bool accepted = false;
		std::string name;
		uint64_t size = 0;
		int64_t modified_unix_ms = 0;
		std::vector<uint8_t> data; // in memory
		uint64_t received = 0;
		// With cfg.file_directory: the temporary file being written.
		int fd = -1;
		std::string temp_path;
		// An answer to FetchRequest `answer` (file-clipboard, file-share):
		// its reply, then raw bytes or more listing frames.
		uint64_t answer = 0;
		std::unique_ptr<gdp::FrameThenRawReader> answer_reader;
		gdp::FrameReader listing_reader;
		bool raw = false;
		bool listing = false;
		~Incoming() {
			if (fd >= 0) ::close(fd);
			if (!temp_path.empty()) ::unlink(temp_path.c_str());
		}
	};
	std::list<std::unique_ptr<Incoming>> incoming;
	std::set<std::string> saved_names;
	// The FileLists it still answers from, by id, with the paths behind
	// them (§7.12); loop thread.
	uint64_t list_id = 0;
	std::map<uint64_t, gdp::LocalFileList> lists;

	// The viewer's latest FileList, as client_file_list() gives it; the
	// host's reads of its files, by fetch id (both guarded by `mu`).
	std::string client_list;
	uint64_t client_list_id = 0;
	std::map<uint64_t, FetchResult> fetches;
	std::map<uint64_t, std::string> client_shares; // the viewer's shared folders, by id
	uint64_t next_fetch_id = 1;

	mutable std::mutex mu; // guards `obs`, `microphone_log` and `keyframe_wanted`
	Observed obs;
	std::vector<MicrophonePacket> microphone_log;
	std::optional<MicrophonePacket> latest_microphone;
	std::vector<ReceivedFile> received_files;
	bool keyframe_wanted = false;

	// Loop thread only.
	uint64_t epoch_us = 0;
	uint32_t next_frame_id = 0;
	uint16_t next_audio_seq = 0;
	uint32_t width = 0;
	uint32_t height = 0;
	std::string codec; // the one accepted
	std::string clipboard;

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
			if (st != gdp::ConnectionState::kShutdown) return;
			// Its file streams go with it, unanswered.
			incoming.remove_if([p](const std::unique_ptr<Incoming> &f) { return f->peer == p; });
			if (p != viewer) return;
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
			obs.client_name = hello.client_name();
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
		codec = chosen;
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
			if (c == gdp::kCapabilityClipboard) p.clipboard = true;
			if (c == gdp::kCapabilityFile) p.file = true;
			if (c == gdp::kCapabilityRefine) p.refine = true;
			if (c == gdp::kCapabilityFileClipboard) p.file_clipboard = true;
			if (c == gdp::kCapabilityFileShare) p.file_share = true;
		}
		p.file_clipboard = p.file_clipboard && p.file && p.clipboard;
		p.file_share = p.file_share && p.file;
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

		// §7.12: the viewer's file streams, and the files "copied" here.
		if (p.file) {
			Peer *peer = &p;
			p.conn->on_stream = [this, peer](std::unique_ptr<gdp::Stream> s) { on_file_stream(peer, std::move(s)); };
			p.conn->allow_streams(gdp::kFileStreamsAtOnce);
			if (!cfg.host_files.empty()) list_files(cfg.host_files);
		}

		// §7.9: and the current clipboard text, if there is any.
		if (p.clipboard && !clipboard.empty()) {
			gdp::session::ControlEnvelope clip;
			clip.mutable_clipboard()->set_mime_type(gdp::kClipboardMimeText);
			clip.mutable_clipboard()->set_data(clipboard);
			send(p, clip);
		}

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
		// §7.3: pyrowave is full-range BT.709 either way; the block codecs
		// take their default here.
		const bool pyrowave = codec == "pyrowave";
		color->set_matrix(pyrowave ? gdp::session::COLOR_MATRIX_BT709 : gdp::session::COLOR_MATRIX_BT601);
		color->set_range(pyrowave ? gdp::session::COLOR_RANGE_FULL : gdp::session::COLOR_RANGE_LIMITED);
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
		case E::kRefinePause: {
			std::lock_guard lock(mu);
			obs.refine_pauses++;
			obs.refine_paused = env.refine_pause().paused();
			break;
		}
		case E::kDiagnosticsReport: {
			std::lock_guard lock(mu);
			obs.diagnostics_report = env.diagnostics_report().text();
			break;
		}
		case E::kFileList: {
			if (!p.file_clipboard) break;
			std::string lines;
			for (const auto &f : env.file_list().files()) {
				lines += std::to_string(f.parent()) + " " + f.name() + (f.directory() ? "/" : "") +
					(f.unlisted() ? "?" : "") + "\n";
			}
			std::lock_guard lock(mu);
			obs.client_file_lists++;
			client_list = lines;
			client_list_id = env.file_list().list_id();
			break;
		}
		case E::kFileShare: {
			if (!p.file_share) break;
			const auto &share = env.file_share();
			std::lock_guard lock(mu);
			obs.share_messages++;
			if (share.removed()) {
				client_shares.erase(share.share_id());
			} else {
				client_shares[share.share_id()] = share.name();
			}
			break;
		}
		case E::kClipboard: {
			const auto &c = env.clipboard();
			if (p.clipboard && c.mime_type() == gdp::kClipboardMimeText && !c.data().empty() &&
				c.data().size() <= gdp::kMaxClipboardBytes) {
				clipboard = c.data();
			}
			std::lock_guard lock(mu);
			obs.clipboard_messages++;
			obs.last_clipboard_mime = c.mime_type();
			obs.last_clipboard = c.data();
			break;
		}
		default:
			break;
		}
	}

	// --- File transfer (§7.12) ---

	void on_file_stream(Peer *p, std::unique_ptr<gdp::Stream> stream) {
		auto owned = std::make_unique<Incoming>();
		Incoming *f = owned.get();
		f->peer = p;
		f->stream = std::move(stream);
		f->stream->on_data = [this, f](const uint8_t *data, size_t len) { on_file_data(f, data, len); };
		f->stream->on_fin = [this, f] { on_file_fin(f); };
		f->stream->on_reset = [this, f](uint64_t) {
			{
				std::lock_guard lock(mu);
				if (f->answer) {
					fetches[f->answer].state = FetchResult::State::kReset;
				} else {
					obs.files_cancelled++;
				}
			}
			drop_file(f);
		};
		incoming.push_back(std::move(owned));
		std::lock_guard lock(mu);
		obs.file_streams_open = static_cast<uint32_t>(incoming.size());
	}

	void on_file_data(Incoming *f, const uint8_t *data, size_t len) {
		// Kept in memory: the window comes straight back.
		f->stream->consume(len);
		if (f->answer) {
			on_answer_data(f, data, len);
			return;
		}
		if (!f->accepted) {
			switch (f->reader.feed(data, len)) {
			case gdp::FileStreamReader::State::kWaiting: return;
			case gdp::FileStreamReader::State::kError:
				close_peer(*f->peer, f->reader.error_code());
				drop_file(f);
				return;
			case gdp::FileStreamReader::State::kOpened: break;
			}
			std::vector<uint8_t> rest = f->reader.take_data();
			gdp::session::FileOpen open;
			if (f->reader.kind() == gdp::kStreamKindFile && open.ParseFromString(f->reader.params()) &&
				open.has_answer()) {
				// The reply follows the StreamOpen at once.
				if (start_answer(f, open.answer().fetch_id()) && !rest.empty()) {
					on_answer_data(f, rest.data(), rest.size());
				}
				return;
			}
			if (!rest.empty()) {
				// Bytes before "accepted".
				close_peer(*f->peer, code(gdp::ErrorCode::kMalformedFrame));
				drop_file(f);
				return;
			}
			on_file_offer(f);
			return;
		}
		if (len > f->size - f->received) {
			end_file(f, false, gdp::session::FILE_ERROR_SIZE_MISMATCH);
			return;
		}
		f->received += len;
		if (f->fd >= 0) {
			for (size_t done = 0; done < len;) {
				ssize_t n = ::write(f->fd, data + done, len - done);
				if (n < 0 && errno == EINTR) continue;
				if (n < 0) return end_file(f, false, gdp::session::FILE_ERROR_WRITE_FAILED);
				done += size_t(n);
			}
		} else {
			f->data.insert(f->data.end(), data, data + len);
		}
		if (cfg.file_fail_after && f->received >= cfg.file_fail_after) {
			end_file(f, false, gdp::session::FILE_ERROR_WRITE_FAILED);
		}
	}

	void on_file_offer(Incoming *f) {
		if (f->reader.kind() != gdp::kStreamKindFile) {
			f->stream->reset(code(gdp::ErrorCode::kUnsupported));
			drop_file(f);
			return;
		}
		gdp::session::FileOpen open;
		if (!open.ParseFromString(f->reader.params())) {
			close_peer(*f->peer, code(gdp::ErrorCode::kMalformedFrame));
			drop_file(f);
			return;
		}
		if (open.has_request()) {
			serve_file(f, open.request());
			return;
		}
		if (open.has_listing()) {
			serve_listing(f, open.listing());
			return;
		}
		f->name = open.offer().name();
		f->size = open.offer().size();
		f->modified_unix_ms = open.offer().modified_unix_ms();
		{
			std::lock_guard lock(mu);
			obs.files_offered++;
			obs.last_file_name = f->name;
		}
		if (!open.has_offer()) return end_file(f, true, gdp::session::FILE_ERROR_UNSUPPORTED);
		if (!gdp::valid_file_name(f->name)) return end_file(f, true, gdp::session::FILE_ERROR_BAD_NAME);
		if (cfg.file_refuse) return end_file(f, true, static_cast<gdp::session::FileErrorCode>(cfg.file_refuse));
		if (cfg.file_ignore_offers) return;
		if (!cfg.file_directory.empty()) {
			std::string templ = cfg.file_directory + "/.loopback-receiving-XXXXXX";
			f->fd = ::mkstemp(templ.data());
			if (f->fd < 0) return end_file(f, true, gdp::session::FILE_ERROR_WRITE_FAILED);
			f->temp_path = templ;
		}
		f->accepted = true;
		gdp::session::FileReply reply;
		reply.mutable_accepted();
		f->stream->send_message(reply);
	}

	void on_file_fin(Incoming *f) {
		if (f->answer) {
			{
				std::lock_guard lock(mu);
				fetches[f->answer].finished = true;
			}
			drop_file(f);
			return;
		}
		if (!f->accepted) {
			drop_file(f);
			return;
		}
		if (f->received != f->size) {
			end_file(f, false, gdp::session::FILE_ERROR_SIZE_MISMATCH);
			return;
		}
		std::string saved = f->name;
		std::string path;
		if (f->fd >= 0) {
			if (f->modified_unix_ms > 0) {
				struct timeval times[2] = {};
				::gettimeofday(&times[0], nullptr);
				times[1].tv_sec = f->modified_unix_ms / 1000;
				times[1].tv_usec = int((f->modified_unix_ms % 1000) * 1000);
				::futimes(f->fd, times);
			}
			::close(f->fd);
			f->fd = -1;
			// link() fails on a taken name, so nothing is ever replaced; the
			// temporary name goes with the Incoming.
			for (unsigned n = 1;; n++) {
				path = cfg.file_directory + "/" + saved;
				if (::link(f->temp_path.c_str(), path.c_str()) == 0) break;
				if (errno != EEXIST || n > 10000) return end_file(f, false, gdp::session::FILE_ERROR_WRITE_FAILED);
				saved = gdp::numbered_file_name(f->name, n);
			}
		} else {
			for (unsigned n = 1; saved_names.count(saved); n++) saved = gdp::numbered_file_name(f->name, n);
			saved_names.insert(saved);
		}
		gdp::session::FileReply reply;
		reply.mutable_saved()->set_name(saved);
		// Only when there is one: in memory, it says nothing (an older host).
		reply.mutable_saved()->set_directory(cfg.file_directory);
		f->stream->send_message(reply);
		f->stream->send(nullptr, 0, true);
		{
			std::lock_guard lock(mu);
			obs.files_saved++;
			received_files.push_back({f->name, saved, f->modified_unix_ms, std::move(f->data), path, f->size});
		}
		drop_file(f);
	}

	// --- Copied files (§7.12) ---

	void list_files(const std::vector<std::string> &paths) {
		list_id++;
		bool tree = viewer && viewer->file_clipboard;
		size_t budget = cfg.file_list_budget ? cfg.file_list_budget : gdp::kFileListBudgetBytes;
		gdp::LocalFileList list = gdp::LocalFileList::build(list_id, paths, tree, budget);
		gdp::session::ControlEnvelope env;
		*env.mutable_file_list() = list.listing();
		lists[list_id] = std::move(list);
		while (lists.size() > std::max<size_t>(1, cfg.file_kept_lists)) lists.erase(lists.begin());
		if (viewer && viewer->accepted && viewer->file) send(*viewer, env);
		std::lock_guard lock(mu);
		obs.file_lists_sent++;
		obs.file_list_id = list_id;
	}

	// Answers a FileRequest from a list sent: reply, the bytes asked for
	// (§7.12's range rules), FIN.
	void serve_file(Incoming *f, const gdp::session::FileRequest &request) {
		{
			std::lock_guard lock(mu);
			obs.files_requested++;
		}
		auto it = lists.find(request.list_id());
		uint32_t index = request.index();
		int fd = -1;
		struct stat st = {};
		if (it != lists.end() && index < it->second.size() && !it->second.is_directory(index)) {
			fd = ::open(it->second.path(index).c_str(), O_RDONLY | O_CLOEXEC);
			if (fd >= 0 && (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode))) {
				::close(fd);
				fd = -1;
			}
		}
		gdp::session::FileReply reply;
		if (fd < 0) {
			reply.mutable_refused()->set_code(gdp::session::FILE_ERROR_GONE);
			f->stream->send_message(reply);
			f->stream->send(nullptr, 0, true);
			{
				std::lock_guard lock(mu);
				obs.file_requests_refused++;
			}
			drop_file(f);
			return;
		}
		uint64_t file_size = uint64_t(st.st_size);
		uint64_t offset = cfg.file_ignore_ranges ? 0 : std::min<uint64_t>(request.offset(), file_size);
		uint64_t size = file_size - offset;
		if (!cfg.file_ignore_ranges && request.length()) size = std::min(size, request.length());
		std::string data(size_t(size), '\0');
		ssize_t n = ::pread(fd, data.data(), data.size(), off_t(offset));
		::close(fd);
		data.resize(n > 0 ? size_t(n) : 0);
		const std::string &path = it->second.path(index);
		auto *sending = reply.mutable_sending();
		sending->set_name(path.substr(path.find_last_of('/') + 1));
		sending->set_size(data.size());
		sending->set_modified_unix_ms(int64_t(st.st_mtimespec.tv_sec) * 1000 + st.st_mtimespec.tv_nsec / 1000000);
		if (!cfg.file_ignore_ranges) {
			sending->set_offset(offset);
			sending->set_file_size(file_size);
		}
		f->stream->send_message(reply);
		f->stream->send(reinterpret_cast<const uint8_t *>(data.data()), data.size(), true);
		{
			std::lock_guard lock(mu);
			obs.files_served++;
		}
		// Let go gracefully: our FIN is queued behind the bytes.
		drop_file(f);
	}

	// Answers a FileListingRequest (file-clipboard): FileReply{listing}
	// frames, then FIN; or refused GONE.
	void serve_listing(Incoming *f, const gdp::session::FileListingRequest &request) {
		auto it = lists.find(request.list_id());
		std::vector<gdp::session::FileListing> frames;
		size_t budget = cfg.file_list_budget ? cfg.file_list_budget : gdp::kFileListBudgetBytes;
		bool ok = f->peer->file_clipboard && it != lists.end() &&
			it->second.list_folder(request.index(), &frames, budget);
		{
			std::lock_guard lock(mu);
			obs.listings_requested++;
			if (!ok) obs.listings_refused++;
		}
		gdp::session::FileReply reply;
		if (!ok) {
			reply.mutable_refused()->set_code(gdp::session::FILE_ERROR_GONE);
			f->stream->send_message(reply);
		}
		for (auto &frame : frames) {
			*reply.mutable_listing() = std::move(frame);
			f->stream->send_message(reply);
		}
		f->stream->send(nullptr, 0, true);
		drop_file(f);
	}

	// Answers `refused` (before acceptance) or `failed`, then FIN.
	void end_file(Incoming *f, bool refused, gdp::session::FileErrorCode error) {
		gdp::session::FileReply reply;
		(refused ? reply.mutable_refused() : reply.mutable_failed())->set_code(error);
		f->stream->send_message(reply);
		f->stream->send(nullptr, 0, true);
		{
			std::lock_guard lock(mu);
			(refused ? obs.files_refused : obs.files_failed)++;
		}
		drop_file(f);
	}

	// --- The viewer's files, read by the host (file-clipboard, file-share) ---

	void send_fetch(uint64_t fetch_id, const FetchRequest &r) {
		if (!viewer || !viewer->accepted) return;
		gdp::session::ControlEnvelope env;
		auto *fetch = env.mutable_file_fetch();
		fetch->set_fetch_id(fetch_id);
		fetch->set_list_id(r.list_id);
		fetch->set_index(r.index);
		fetch->set_offset(r.offset);
		fetch->set_length(r.length);
		fetch->set_listing(r.listing);
		fetch->set_share_id(r.share_id);
		fetch->set_path(r.path);
		send(*viewer, env);
	}

	// Whether the stream answers a fetch still waiting; if not, it is reset.
	bool start_answer(Incoming *f, uint64_t fetch_id) {
		bool known;
		{
			std::lock_guard lock(mu);
			auto it = fetches.find(fetch_id);
			known = it != fetches.end() && it->second.state == FetchResult::State::kPending;
			obs.fetch_answers++;
		}
		if (!known) {
			f->stream->reset(0);
			drop_file(f);
			return false;
		}
		f->answer = fetch_id;
		f->answer_reader = std::make_unique<gdp::FrameThenRawReader>(gdp::kMaxFrameSize);
		return true;
	}

	void on_answer_data(Incoming *f, const uint8_t *data, size_t len) {
		if (f->raw) {
			std::lock_guard lock(mu);
			auto &d = fetches[f->answer].data;
			d.insert(d.end(), data, data + len);
			return;
		}
		if (f->listing) {
			gdp::session::FileReply reply;
			f->listing_reader.feed_and_drain(data, len, &reply, [&] {
				add_listing(f->answer, reply.listing());
				return true;
			});
			return;
		}
		auto state = f->answer_reader->feed(data, len);
		if (state == gdp::FrameThenRawReader::State::kError) {
			close_peer(*f->peer, code(gdp::ErrorCode::kMalformedFrame));
			drop_file(f);
			return;
		}
		if (state == gdp::FrameThenRawReader::State::kWaiting) return;
		gdp::session::FileReply reply;
		reply.ParseFromString(f->answer_reader->frame());
		std::vector<uint8_t> rest = f->answer_reader->take_data();
		std::lock_guard lock(mu);
		FetchResult &r = fetches[f->answer];
		if (reply.has_refused()) {
			r.state = FetchResult::State::kRefused;
			r.error = reply.refused().code();
		} else if (reply.has_sending()) {
			r.state = FetchResult::State::kSending;
			r.name = reply.sending().name();
			r.size = reply.sending().size();
			r.offset = reply.sending().offset();
			r.file_size = reply.sending().file_size();
			r.modified_unix_ms = reply.sending().modified_unix_ms();
			r.data = std::move(rest);
			f->raw = true;
		} else if (reply.has_listing()) {
			r.state = FetchResult::State::kListing;
			r.first_index = reply.listing().first_index();
			f->listing = true;
			for (const auto &e : reply.listing().files()) r.entries.push_back(e.name() + (e.directory() ? "/" : ""));
			gdp::session::FileReply more;
			f->listing_reader.feed_and_drain(rest.data(), rest.size(), &more, [&] {
				for (const auto &e : more.listing().files()) r.entries.push_back(e.name() + (e.directory() ? "/" : ""));
				return true;
			});
		}
	}

	void add_listing(uint64_t fetch_id, const gdp::session::FileListing &listing) {
		std::lock_guard lock(mu);
		FetchResult &r = fetches[fetch_id];
		for (const auto &e : listing.files()) r.entries.push_back(e.name() + (e.directory() ? "/" : ""));
	}

	void reset_answer(uint64_t fetch_id) {
		for (auto &i : incoming) {
			if (i->answer == fetch_id) {
				i->stream->reset(0);
				drop_file(i.get());
				return;
			}
		}
	}

	void drop_file(Incoming *f) {
		incoming.remove_if([f](const std::unique_ptr<Incoming> &i) { return i.get() == f; });
		std::lock_guard lock(mu);
		obs.file_streams_open = static_cast<uint32_t>(incoming.size());
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
			case gdp::session::InputEnvelope::kGamepadConnect:
				ev.kind = TestHost::InputEvent::GamepadConnect;
				ev.code = env.gamepad_connect().pad_index();
				ev.name = env.gamepad_connect().name();
				break;
			case gdp::session::InputEnvelope::kGamepad: {
				const auto &g = env.gamepad();
				ev.kind = TestHost::InputEvent::GamepadState;
				ev.code = g.pad_index();
				ev.axis_count = static_cast<uint32_t>(g.axes_size());
				ev.button_count = static_cast<uint32_t>(g.buttons_size());
				for (int i = 0; i < std::min(g.axes_size(), 6); i++) ev.axes[i] = g.axes(i);
				for (int i = 0; i < std::min(g.buttons_size(), 26); i++) {
					if (g.buttons(i)) ev.buttons |= 1u << i;
				}
				break;
			}
			case gdp::session::InputEnvelope::kGamepadDisconnect:
				ev.kind = TestHost::InputEvent::GamepadDisconnect;
				ev.code = env.gamepad_disconnect().pad_index();
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

	// With `refine` in effect a payload is wrapped as §9.5 does (an empty
	// layer unless one is given), unless `raw` says to send it as is.
	void send_video(const std::vector<uint8_t> &data, bool keyframe, const std::vector<uint16_t> &drop,
		size_t max_payload, const gdp::RefineLayer *layer = nullptr, bool raw = false) {
		if (!viewer) return;
		if (viewer->refine && !raw) {
			std::vector<uint8_t> wrapped;
			gdp::RefineLayer none;
			if (!gdp::refine_pack_frame(data.data(), data.size(), layer ? *layer : none, 3, &wrapped)) return;
			return send_video(wrapped, keyframe, drop, max_payload, nullptr, true);
		}
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
	// Joined with "/" + name: no trailing slash of its own.
	while (m.cfg.file_directory.size() > 1 && m.cfg.file_directory.back() == '/') m.cfg.file_directory.pop_back();
	m.clipboard = config.clipboard;
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

void TestHost::send_refined_frame(std::vector<uint8_t> data, bool keyframe, gdp::RefineLayer layer) {
	impl_->post([m = impl_.get(), data = std::move(data), keyframe, layer = std::move(layer)] {
		m->send_video(data, keyframe, {}, 0, &layer);
	});
}

void TestHost::send_raw_video(std::vector<uint8_t> payload, bool keyframe) {
	impl_->post([m = impl_.get(), payload = std::move(payload), keyframe] {
		m->send_video(payload, keyframe, {}, 0, nullptr, true);
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

void TestHost::send_file_list(std::vector<std::string> paths) {
	impl_->post([m = impl_.get(), paths = std::move(paths)] { m->list_files(paths); });
}

uint64_t TestHost::fetch(FetchRequest request) {
	uint64_t id;
	{
		std::lock_guard lock(impl_->mu);
		id = impl_->next_fetch_id++;
		impl_->fetches[id] = FetchResult{};
	}
	impl_->post([m = impl_.get(), id, request = std::move(request)] { m->send_fetch(id, request); });
	return id;
}

bool TestHost::fetch_result(uint64_t fetch_id, FetchResult *out) const {
	std::lock_guard lock(impl_->mu);
	auto it = impl_->fetches.find(fetch_id);
	if (it == impl_->fetches.end()) return false;
	*out = it->second;
	return true;
}

void TestHost::reset_fetch(uint64_t fetch_id) {
	impl_->post([m = impl_.get(), fetch_id] { m->reset_answer(fetch_id); });
}

std::string TestHost::client_shares() const {
	std::lock_guard lock(impl_->mu);
	std::string lines;
	for (const auto &[id, name] : impl_->client_shares) lines += std::to_string(id) + " " + name + "\n";
	return lines;
}

std::string TestHost::client_file_list(uint64_t *list_id) const {
	std::lock_guard lock(impl_->mu);
	if (list_id) *list_id = impl_->client_list_id;
	return impl_->client_list;
}

void TestHost::send_clipboard(std::string mime_type, std::string data) {
	impl_->post([m = impl_.get(), mime_type = std::move(mime_type), data = std::move(data)] {
		if (mime_type == gdp::kClipboardMimeText && !data.empty()) m->clipboard = data;
		if (!m->viewer) return;
		gdp::session::ControlEnvelope env;
		env.mutable_clipboard()->set_mime_type(mime_type);
		env.mutable_clipboard()->set_data(data);
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

bool TestHost::received_file(size_t index, ReceivedFile *out) const {
	std::lock_guard lock(impl_->mu);
	if (index >= impl_->received_files.size()) return false;
	*out = impl_->received_files[index];
	return true;
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
