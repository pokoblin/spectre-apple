// A minimal GDP session host (the wraith side of gdp-spec.md §6-§10),
// written from the spec, for tests and the app's loopback demo: listens on
// 127.0.0.1 with a throwaway certificate and a static token (§6.11),
// authenticates one viewer, accepts it, streams whatever video frames it is
// given as datagrams, and records everything the client sends.
//
// Runs its own thread (its Transport's dispatch loop). Every public method
// is thread-safe: commands are queued to that thread.
#pragma once

#include <cstdint>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace gdpcore {

class TestHost {
public:
	struct Config {
		std::string scratch_dir; // for the certificate's PEM files
		std::string token = "test-token";
		std::vector<std::string> codecs = {"h264", "h265"}; // what this host "encodes"
		std::vector<std::string> capabilities;              // what it supports (§6.7)
		uint32_t width = 1920;
		uint32_t height = 1080;
		bool audio = false; // advertise {48000, 2, 10, "opus"}
		// Misbehaviour, for tests:
		std::string force_codec;     // accept with this codec whatever was offered
		uint64_t refuse_code = 0;    // close with this code after a good hello
		std::string reject_reason;   // send SessionReject, then close with AUTH_FAILED
		bool ping_before_accept = false;
		uint32_t first_frame_id = 0; // §9.1 says 0; tests use others to cross the 2^32 wrap
		// Keep a pointer the way a host does: absolute motion places it,
		// relative motion moves it (pixels of the output, clamped to it),
		// and after a batch of input that moved it relatively, report it
		// with CursorPosition (§7.4).
		bool simulate_pointer = false;
	};

	// One input event as received (§8.2, §8.3), in order.
	struct InputEvent {
		enum Kind : uint8_t { Key = 1, Motion, Button, Axis, Touch };
		Kind kind;
		uint32_t code = 0;    // HID usage, BTN_* code or touch_id
		bool pressed = false; // key and button
		double x = 0, y = 0;  // motion dx/dy, axis horizontal/vertical, touch position
		bool absolute = false;
		int32_t phase = 0;    // touch
	};
	static constexpr size_t kMaxInputLog = 8192;

	struct Observed {
		bool connected = false;
		bool hello_received = false;
		std::string token;
		std::vector<std::string> codecs;
		std::vector<std::string> capabilities;
		std::vector<std::string> decoders;
		bool take_over = false;
		bool via_gateway = false;
		int32_t network_profile = 0;
		uint32_t requested_width = 0;
		uint32_t requested_height = 0;
		bool accepted = false;
		std::string accepted_codec;
		bool closed = false;
		uint64_t close_code = 0; // what this host closed with
		// The accepted viewer's connection ended, and how (its close code
		// and reason as the transport reports them; an idle timeout has no code).
		bool viewer_closed = false;
		uint64_t viewer_close_code = 0;
		std::string viewer_close_reason;

		uint32_t stats_reports = 0;
		struct Stats {
			uint32_t rtt_us = 0;
			bool has_stream = false;
			uint32_t stream_id = 0;
			uint32_t highest_frame_id_acked = 0;
			uint64_t loss_bitmap = 0;
			uint32_t decode_us = 0;
			uint32_t present_us = 0;
			uint32_t interval_us = 0;
			uint64_t bytes_received = 0;
			int32_t delay_min_us = 0;
			int32_t delay_avg_us = 0;
			uint32_t delay_samples = 0;
			uint32_t trains = 0;
			uint32_t train_datagrams = 0; // of the last train
			uint32_t train_bytes = 0;
		};
		Stats last_stats;
		std::vector<uint32_t> lost_frame_ids; // frames any report marked lost, deduplicated
		uint64_t bytes_reported = 0;

		uint32_t keyframe_requests = 0;
		std::vector<std::pair<uint32_t, uint32_t>> resolution_requests;
		bool logout_requested = false;
		uint32_t pongs = 0;
		uint64_t last_pong_nonce = 0;
		std::string diagnostics_report;

		std::vector<std::pair<uint32_t, bool>> keys;
		uint32_t pointer_motions = 0;
		double last_motion_x = 0, last_motion_y = 0;
		bool last_motion_absolute = false;
		std::vector<std::pair<uint32_t, bool>> buttons;
		double axis_vertical_sum = 0;
		double axis_horizontal_sum = 0;
		uint32_t touches = 0;
		std::vector<InputEvent> inputs; // the first kMaxInputLog
		double pointer_x = 0.5, pointer_y = 0.5; // with simulate_pointer
		uint32_t cursor_positions_sent = 0;
		bool input_before_accept = false;

		uint32_t frames_sent = 0;
		uint32_t next_frame_id = 0;
		uint16_t max_datagram_size = 0;
	};

	TestHost();
	~TestHost();
	TestHost(const TestHost &) = delete;
	TestHost &operator=(const TestHost &) = delete;

	bool start(const Config &config, std::string *error);
	uint16_t port() const { return port_; }
	const std::string &cert_sha256() const { return cert_sha256_; }

	// Sends one coded frame as video datagrams (§9), with the next frame_id
	// and the session clock as pts. Slices whose index is in `drop_slices`
	// are not sent (simulated loss). `max_payload` 0 = what the path allows.
	void send_video_frame(std::vector<uint8_t> data, bool keyframe, std::vector<uint16_t> drop_slices = {},
		size_t max_payload = 0);
	void send_audio_packet(uint16_t seq, uint32_t pts, std::vector<uint8_t> opus);
	void send_ping(uint64_t nonce);
	void send_cursor_shape(uint32_t w, uint32_t h, uint32_t hot_x, uint32_t hot_y, std::vector<uint8_t> argb);
	void send_cursor_position(double x, double y);
	void send_displays_changed(uint32_t w, uint32_t h);
	void send_network_profile(int32_t profile);
	void send_gateway_path(uint32_t upstream_rtt_us);
	void send_diagnostics_request();
	void close(uint64_t code);

	// Whether a keyframe was asked for (KeyframeRequest, or a newly reported
	// loss) since the last call -- the cue to send one.
	bool take_keyframe_wanted();

	Observed observed() const;

private:
	struct Impl;
	std::unique_ptr<Impl> impl_;
	uint16_t port_ = 0;
	std::string cert_sha256_;
};

} // namespace gdpcore
