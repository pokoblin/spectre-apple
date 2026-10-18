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
#include "gdp/file_transfer.hpp"
#include "gdp/framing.hpp"
#include "gdp/refine.hpp"
#include "gdp/video_reassembler.hpp"

#include <cstdint>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace gdp {
class Stream;
}

namespace gdp::session {
class ControlEnvelope;
class FileOpen;
class FileReply;
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

// With `refine` in effect (gdp-spec.md §7.8, §9.5), a frame's lossless
// layer: what to do to the overlay plane, in order (§9.6). `bgra` holds
// the tiles' pixels, concatenated in tile order, each row-major at
// width * 4 bytes a row, opaque.
struct RefineFrameLayer {
	bool reset = false;
	const gdp::RefineRect *clears = nullptr;
	size_t clear_count = 0;
	const gdp::RefineRect *tiles = nullptr;
	size_t tile_count = 0;
	const uint8_t *bgra = nullptr;
	size_t bgra_len = 0;
};

struct VideoFrame {
	uint8_t stream_id = 0;
	uint32_t frame_id = 0;
	bool keyframe = false;
	uint32_t pts = 0;
	// The codec's bytes; none for a layer-only frame (refine).
	const uint8_t *data = nullptr;
	size_t len = 0;
	// Its lossless layer, with `refine` in effect; null otherwise.
	const RefineFrameLayer *refine = nullptr;
};

// How a file transfer ended (gdp-spec.md §7.12).
enum class FileOutcome : int32_t {
	kSaved = 1,     // the host stored it, under the name it reported
	kRefused = 2,   // the host refused the offer (a FileErrorCode says why)
	kFailed = 3,    // the host accepted, then gave up (a FileErrorCode says why)
	kCancelled = 4, // the host reset the stream
	kTimedOut = 5,  // no answer to the offer in time
	kLost = 6,      // the connection ended first
};

// One file of a host's FileList (§7.12).
struct FileListEntry {
	std::string name;
	uint64_t size = 0;
	int64_t modified_unix_ms = 0;
	bool directory = false;
	// file-clipboard: 0 for what was copied, else 1 + the index of the
	// folder it is in; a folder whose contents aren't listed yet.
	uint32_t parent = 0;
	bool unlisted = false;
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
		std::string client_name;               // informational (§6.2): this machine's name
		uint32_t display_width = 0;            // 0x0: keep the session's size
		uint32_t display_height = 0;
		uint32_t display_refresh_mhz = 0;
		double display_scale = 0;
		bool take_over = false;
		int32_t network_profile = 0; // NetworkProfile
		// §9.3: after a loss, drop non-keyframes until the host's repair keyframe.
		bool drop_until_keyframe_after_loss = true;
		// §7.12: how long an offer waits for the host's answer; 0 is the
		// spec's 30 s (tests shorten it).
		uint32_t file_reply_timeout_ms = 0;
	};

	struct Callbacks {
		std::function<void(const AcceptInfo &)> accepted;
		// Exactly once, at the end: the §12 code (the peer's, or ours when we
		// closed for a protocol violation), a description, and whether the
		// host's certificate was the reason.
		// `connection_lost`: the connection failed rather than anyone ending
		// it (an idle timeout, a reset, a network error, no answer at all):
		// no §12 code, not closed by us, not refused at the certificate.
		std::function<void(uint64_t code, const std::string &reason, bool certificate_rejected, bool connection_lost)>
			closed;
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
		// The host's clipboard text, UTF-8 as sent (§7.9): only with
		// `clipboard` in effect, never empty or over the size limit.
		std::function<void(const uint8_t *text, size_t len)> clipboard_text;
		// File transfer (§7.12), per offer_file() id. `file_accepted`: send
		// its bytes now. `file_progress`: how many of them the host has
		// acknowledged, coalesced. `file_finished`: exactly once per offer
		// (except after cancel_file()), with the FileErrorCode for kRefused
		// and kFailed, and for kSaved the stored name and the host's folder
		// it is in (empty if the host doesn't say, and for a fetch).
		std::function<void(uint64_t id)> file_accepted;
		std::function<void(uint64_t id, uint64_t acked)> file_progress;
		std::function<void(uint64_t id, FileOutcome outcome, int32_t error, const std::string &saved_name,
			const std::string &saved_directory)>
			file_finished;
		// Copied files (§7.12): the host's latest FileList (none: nothing is
		// copied any more). Then, per request_file() id, the file's name, size
		// and time as the host sends it, and its bytes in order; hand each
		// piece back with consume_file_data() once it is stored. A fetch ends
		// in file_finished: kSaved (every byte arrived; the name is the
		// host's), kRefused, kFailed (short), kCancelled, kTimedOut or kLost.
		std::function<void(uint64_t list_id, const std::vector<FileListEntry> &files)> file_list;
		// `size` bytes follow, from `offset` of a file `file_size` long:
		// what was asked for, also from a host that ignores ranges.
		std::function<void(uint64_t id, const std::string &name, uint64_t size, int64_t modified_unix_ms,
			uint64_t offset, uint64_t file_size)>
			file_sending;
		std::function<void(uint64_t id, const uint8_t *data, size_t len)> file_data;
		// file-clipboard: per request_listing() id, a folder's entries (one
		// or more batches, indices from `first_index` on), then
		// file_finished: kSaved once all have come, or kRefused (GONE).
		std::function<void(uint64_t id, uint32_t first_index, const std::vector<FileListEntry> &files)>
			file_listing;
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
	// A local clipboard change (§7.9). Dropped before establishment, without
	// `clipboard` in effect, and when empty or over the size limit.
	void send_clipboard_text(const uint8_t *text, size_t len);
	// Lossless refinement (§7.8): whether the host builds the layer. Kept
	// for later connections too (each starts unpaused on the host, so a
	// pause is sent again at SessionAccept); sent only with `refine` in
	// effect.
	void set_refine_paused(bool paused);

	// Input (§8.2, §8.3).
	void send_key(uint32_t hid_usage, bool pressed);
	void send_pointer_motion(double dx, double dy, bool absolute);
	void send_pointer_button(uint32_t button, bool pressed);
	void send_pointer_axis(double horizontal, double vertical);
	void send_touch(uint32_t touch_id, int32_t phase, double x, double y);
	// Gamepads (§8.5): dropped before establishment, without `gamepad` in
	// effect, and for a slot of 4 or more. `axes` holds 6 values and
	// `buttons` 26, in gdp/gamepad.hpp's order; axes are clamped to their
	// ranges, NaN sent as 0.
	void send_gamepad_connect(uint32_t slot, const std::string &name);
	void send_gamepad_state(uint32_t slot, const float *axes, const bool *buttons);
	void send_gamepad_disconnect(uint32_t slot);

	// File transfer (§7.12). Offers a file on a stream of its own and returns
	// its id, or 0 before establishment, without `file` in effect, or for a
	// name that breaks §7.12's rules (gdp::valid_file_name()). The host
	// grants gdp::kFileStreamsAtOnce streams at once: keep no more offers
	// than that unfinished, or the rest wait for a stream while their reply
	// timeout runs.
	uint64_t offer_file(const std::string &name, uint64_t size, int64_t modified_unix_ms);
	// The file's next bytes, once file_accepted has fired; the stream is
	// finished with the last of `size`. False (nothing sent) before then,
	// after the end, or for more than the rest of the file.
	bool send_file_data(uint64_t id, const uint8_t *data, size_t len);
	// Cancels: the stream is reset (code 0). No file_finished follows.
	void cancel_file(uint64_t id);
	// Fetches file `index` of FileList `list_id` (§7.12) on a stream of its
	// own, and returns its id; 0 before establishment or without `file`.
	// The same limit of streams at once as offer_file().
	// `offset` and `length` ask for a range (0, 0: the whole file).
	uint64_t request_file(uint64_t list_id, uint32_t index, uint64_t offset = 0, uint64_t length = 0);
	// file-clipboard: what is in folder `index` of list `list_id`, through
	// file_listing; 0 without file-clipboard in effect.
	uint64_t request_listing(uint64_t list_id, uint32_t index);
	// `len` bytes of a fetched file's file_data are stored: the host may
	// send that much more.
	void consume_file_data(uint64_t id, size_t len);

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

	struct FileTransfer {
		// An offer: kOffered, kSending, kSent. A request: kRequested,
		// kReceiving. A listing request: kListing.
		enum class State { kOffered, kSending, kSent, kRequested, kReceiving, kListing };
		uint64_t id = 0;
		std::unique_ptr<gdp::Stream> stream;
		gdp::FrameReader reader;
		// A request's reply: one frame, then the file.
		std::unique_ptr<gdp::FrameThenRawReader> fetch_reader;
		std::string name;
		uint64_t received = 0;
		State state = State::kOffered;
		uint64_t size = 0;
		uint64_t sent = 0;
		size_t open_frame_len = 0; // acks count the StreamOpen frame too
		uint64_t offered_us = 0;
		// A range request: what was asked for, and, from a host that sent
		// from earlier on, how much to drop before it.
		uint64_t want_offset = 0;
		uint64_t want_length = 0;
		uint64_t skip = 0;
		// The host sends more than was asked for (it ignores ranges): stop
		// once `size` bytes have come.
		bool cut = false;
	};
	void handle_file_data(FileTransfer *t, const uint8_t *data, size_t len);
	void handle_fetch_data(FileTransfer *t, const uint8_t *data, size_t len);
	void handle_fetch_fin(FileTransfer *t);
	void handle_listing_data(FileTransfer *t, const uint8_t *data, size_t len);
	// Opens a file stream for a request or listing request.
	FileTransfer *open_fetch(const gdp::session::FileOpen &file_open, FileTransfer::State state);
	// A fetched file's bytes, past its reply.
	void receive_file_bytes(FileTransfer *t, const uint8_t *data, size_t len);
	// Returns false once `t` is gone (or the connection is being closed).
	bool handle_file_reply(FileTransfer *t, const gdp::session::FileReply &reply);
	// Drops the transfer, then reports it.
	void finish_file(FileTransfer *t, FileOutcome outcome, int32_t error = 0, const std::string &saved_name = {},
		const std::string &saved_directory = {});
	// Offers the host hasn't answered in time.
	void expire_file_offers();
	void handle_video_frame(gdp::VideoFrameReassembler::Frame &frame);
	void deliver(const gdp::VideoFrameReassembler::Frame &frame);
	void send_refine_pause();
	void send_control(const gdp::session::ControlEnvelope &env);
	void send_input(gdp::session::InputEnvelope &env);
	// Closes for a protocol violation (or any local reason) with `code`.
	void fail(uint64_t code, const std::string &reason);
	void report_closed(uint64_t code, const std::string &reason, bool connection_lost = false);

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
	bool clipboard_ = false;                // `clipboard` among them
	bool gamepad_ = false;                  // `gamepad` among them
	bool file_ = false;                     // `file` among them
	bool file_clipboard_ = false;           // `file-clipboard` among them (with `file` and `clipboard`)
	bool refine_ = false;                   // `refine` among them
	bool refine_paused_ = false;            // what the user wants, across connections
	// The latest frame's layer, reused frame to frame.
	gdp::RefineLayer refine_layer_;
	std::vector<uint8_t> refine_bgra_;
	std::map<uint64_t, std::unique_ptr<FileTransfer>> files_;
	uint64_t next_file_id_ = 1;

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
