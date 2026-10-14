// The client end of a GDP session connection (gdp-spec.md §6-§11),
// written from the spec. Opens the control and input streams, says
// SessionHello, checks SessionAccept, reassembles video, hands audio up,
// and keeps the host's rate control fed with StatsReport.
//
// Threading: not thread-safe. Every call, and dispatch() (which fires every
// callback), must come from one thread or serial queue -- GDPKit's Swift
// side owns that queue. Don't destroy the client from inside a callback.
#pragma once

#include "receive_stats.hpp"

#include "gdp/client_connection.hpp"
#include "gdp/framing.hpp"
#include "gdp/video_reassembler.hpp"

#include <cstdint>
#include <deque>
#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace gdp::session {
class ControlEnvelope;
class InputEnvelope;
class OutputDescriptor;
class SessionAccept;
} // namespace gdp::session

namespace gdpcore {

struct Output {
	uint32_t stream_id = 0;
	uint32_t width = 0;
	uint32_t height = 0;
	uint32_t refresh_mhz = 0;
	double scale = 0;
	// session.proto's enum values; 0 = unspecified (the codec's default, §7.3).
	int32_t matrix = 0;
	int32_t range = 0;
	int32_t primaries = 0;
	int32_t transfer = 0;
	uint32_t bit_depth = 0;
	int32_t chroma = 0;
};

struct AcceptInfo {
	std::string codec;
	std::vector<Output> outputs;
	uint32_t bitrate_ceiling_bps = 0;
	bool has_audio = false;
	std::string audio_codec;
	uint32_t audio_sample_rate_hz = 0;
	uint32_t audio_channels = 0;
	uint32_t audio_frame_ms = 0;
	// SessionAccept.microphone (§6.8), kept only when `microphone` is in effect.
	bool has_microphone = false;
	std::string microphone_codec;
	uint32_t microphone_sample_rate_hz = 0;
	uint32_t microphone_channels = 0;
	uint32_t microphone_frame_ms = 0;
	std::vector<std::string> capabilities;
	int32_t network_profile = 0;
	bool via_gateway = false;
	std::string encoder;
	std::string host_user;
	std::string host_name;
};

struct VideoFrame {
	uint8_t stream_id = 0;
	uint32_t frame_id = 0;
	bool keyframe = false;
	uint32_t pts = 0;
	const uint8_t *data = nullptr;
	size_t len = 0;
};

class SessionClient : public gdp::ClientConnection {
public:
	struct Config {
		std::string host;
		uint16_t port = 0;
		std::string token;
		// Redirect.cert_sha256 (or the static-token setup's, §6.11): the
		// only certificate this connection accepts (§2.3).
		std::string cert_sha256;
		std::vector<std::string> codecs;       // preference order (§6.6)
		std::vector<std::string> capabilities; // §6.7; only those this client implements
		std::vector<std::string> decoders;     // informational (§6.2)
		uint32_t display_width = 0;            // 0x0: keep the session's size
		uint32_t display_height = 0;
		uint32_t display_refresh_mhz = 0;
		double display_scale = 0;
		bool take_over = false;
		int32_t network_profile = 0; // NetworkProfile
		// §9.3: after a loss, drop non-keyframes until the host's repair keyframe.
		bool drop_until_keyframe_after_loss = true;
	};

	struct Callbacks {
		std::function<void(const AcceptInfo &)> accepted;
		// Exactly once, at the end: the §12 code (the peer's, or ours when we
		// closed for a protocol violation), a description, and whether the
		// host's certificate was the reason.
		std::function<void(uint64_t code, const std::string &reason, bool certificate_rejected)> closed;
		std::function<void(const std::vector<Output> &)> displays_changed;
		// Return false if the frame could not be used: it then counts as lost (§7.5).
		std::function<bool(const VideoFrame &)> video_frame;
		std::function<void(uint16_t seq, uint32_t pts, const uint8_t *opus, size_t len)> audio_packet;
		// `bgra` is width*height*4 bytes (BGRA in memory, premultiplied), or
		// empty with 0x0 for "no cursor" (§7.4).
		std::function<void(uint32_t w, uint32_t h, uint32_t hot_x, uint32_t hot_y, const uint8_t *bgra)> cursor_shape;
		std::function<void(double x, double y)> cursor_position;
		std::function<void(int32_t profile)> network_profile_changed;
		std::function<void()> diagnostics_requested;
	};

	struct LinkStats {
		uint32_t rtt_us = 0;          // QUIC smoothed RTT plus the gateway leg (§6.10)
		uint32_t upstream_rtt_us = 0; // the gateway leg alone; 0 on a direct session
		uint16_t path_mtu = 0;
		uint16_t max_datagram_size = 0;
		uint32_t stats_reports_sent = 0;
		uint64_t frames_delivered = 0;
		uint64_t frames_dropped = 0; // complete but not delivered (waiting for a keyframe)
		uint64_t microphone_sent = 0;
		uint64_t microphone_dropped = 0; // not established, not negotiated, or the transport refused it
		StreamReceiveStats::Snapshot video;
	};

	explicit SessionClient(Callbacks callbacks);
	~SessionClient() override;

	// Starts connecting. Fails (with `error`) only on bad configuration or
	// immediate local failure; everything after is reported through the
	// callbacks from dispatch().
	bool start(const Config &config, std::string *error);

	bool established() const { return accepted_; }

	// Detach: close with code 0; the desktop session keeps running (§7.10).
	void close();

	// Every 250 ms while established (§7.5). No-op before SessionAccept.
	void send_stats_report();
	// Timings of the latest shown frame, for the next StatsReport.
	void record_frame_timing(uint32_t decode_us, uint32_t present_us);
	// A frame video_frame accepted turned out unusable (the decoder rejected
	// it): reported lost, and frames are dropped until the next keyframe.
	void mark_frame_discarded(uint8_t stream_id, uint32_t frame_id);

	void request_keyframe(uint32_t stream_id);
	void request_resolution(uint32_t stream_id, uint32_t width, uint32_t height);
	void send_logout();
	// The answer to the latest DiagnosticsRequest; ignored without one pending.
	void send_diagnostics_report(const uint8_t *text, size_t len);

	// Input (§8.2, §8.3).
	void send_key(uint32_t hid_usage, bool pressed);
	void send_pointer_motion(double dx, double dy, bool absolute);
	void send_pointer_button(uint32_t button, bool pressed);
	void send_pointer_axis(double horizontal, double vertical);
	void send_touch(uint32_t touch_id, int32_t phase, double x, double y);

	// One Opus packet of the microphone (§10.1) on datagram channel 0x03:
	// seq counts from 0 at SessionAccept, pts is our session clock. Dropped
	// (false) unless established with `microphone` in effect.
	bool send_microphone(const uint8_t *opus, size_t len);

	LinkStats link_stats() const;

private:
	void on_connected() override;
	void on_connection_shutdown() override;

	void handle_control_data(const uint8_t *data, size_t len);
	bool handle_envelope(const gdp::session::ControlEnvelope &env);
	bool handle_accept(const gdp::session::SessionAccept &accept);
	void handle_datagram(const uint8_t *data, size_t len, uint64_t arrival_us);
	void handle_video_frame(gdp::VideoFrameReassembler::Frame &frame);
	void deliver(const gdp::VideoFrameReassembler::Frame &frame);
	void send_control(const gdp::session::ControlEnvelope &env);
	void send_input(gdp::session::InputEnvelope &env);
	// Closes for a protocol violation (or any local reason) with `code`.
	void fail(uint64_t code, const std::string &reason);
	void report_closed(uint64_t code, const std::string &reason);

	Callbacks cb_;
	Config config_;
	gdp::Stream *control_ = nullptr;
	gdp::Stream *input_ = nullptr;
	gdp::FrameReader control_reader_;
	bool accepted_ = false;
	bool closed_reported_ = false;
	std::optional<std::pair<uint64_t, std::string>> local_close_; // set by fail()
	std::string rejected_reason_;
	bool diagnostics_pending_ = false;

	uint64_t session_epoch_us_ = 0;
	uint32_t upstream_rtt_us_ = 0;
	std::vector<std::string> capabilities_; // in effect
	bool microphone_ = false;               // `microphone` in effect, with a format
	uint16_t microphone_seq_ = 0;
	uint64_t microphone_sent_ = 0;
	uint64_t microphone_dropped_ = 0;

	struct StreamState {
		explicit StreamState(uint8_t id) : stats(id) {}
		StreamReceiveStats stats;
		// Dropping non-keyframes until a keyframe (§9.3): from the start,
		// after a gap, and after a frame the decoder rejected.
		bool awaiting_keyframe = true;
		uint64_t last_keyframe_request_us = 0;
	};
	StreamState &stream(uint8_t stream_id);
	void drop_until_keyframe(StreamState &st);

	gdp::VideoFrameReassembler reassembler_;
	std::deque<StreamState> streams_; // deque: references stay valid as streams are added
	// Frames completed before SessionAccept was processed (datagrams can
	// overtake the control stream): delivered right after it.
	std::deque<gdp::VideoFrameReassembler::Frame> early_frames_;
	uint64_t frames_delivered_ = 0;
	uint64_t frames_dropped_ = 0;
	uint32_t stats_reports_sent_ = 0;
};

} // namespace gdpcore
