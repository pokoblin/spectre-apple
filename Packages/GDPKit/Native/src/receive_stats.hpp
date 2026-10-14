// What one video stream's receiver measures for StatsReport (gdp-spec.md
// §7.5): which frames completed (the ack/loss window), the one-way delay of
// each frame's first-arriving datagram, frame trains, bytes, and the
// latest decode/present timings. Written from the spec; no transport
// dependency, so it can be driven directly.
#pragma once

#include "gdp/datagram.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace gdp::session {
class StreamStats;
}

namespace gdpcore {

class StreamReceiveStats {
public:
	struct Train {
		uint32_t frame_id = 0;
		uint32_t datagrams = 0;
		uint32_t bytes = 0;
		uint32_t span_us = 0;
	};

	// Read-only view for overlays: what the last report carried, plus the
	// window as it stands.
	struct Snapshot {
		bool has_frames = false;
		uint32_t highest_frame_id = 0;
		uint64_t loss_bitmap = 0;
		uint32_t window_span = 0; // how many of the 64 bits refer to real frames
		int32_t last_delay_min_us = 0;
		int32_t last_delay_avg_us = 0;
		uint32_t last_delay_samples = 0;
		uint64_t last_bytes = 0;
		uint32_t last_interval_us = 0;
	};

	static constexpr size_t kMinTrainDatagrams = 16;
	static constexpr size_t kMaxTrainsPerReport = 8;

	explicit StreamReceiveStats(uint32_t stream_id = 0) : stream_id_(stream_id) {}

	uint32_t stream_id() const { return stream_id_; }

	// Starts the first measurement window (at SessionAccept).
	void start(uint64_t now_us) { window_start_us_ = now_us; }

	// Every video datagram of this stream as it arrives, before reassembly.
	// `arrival_us` is gdp::monotonic_us() when the network thread read it;
	// `session_epoch_us` the same clock at SessionAccept (gdp-spec.md §11).
	void on_datagram(const gdp::VideoDatagramHeader &header, size_t datagram_len, uint64_t arrival_us,
		uint64_t session_epoch_us);
	// A frame finished reassembly.
	void on_frame_completed(uint32_t frame_id);
	// A completed frame was thrown away afterwards: it counts as lost.
	void on_frame_discarded(uint32_t frame_id);
	void record_timing(uint32_t decode_us, uint32_t present_us);

	// The loss bitmap as §7.5 defines it, relative to highest_frame_id().
	uint64_t loss_bitmap() const;
	bool has_frames() const { return have_highest_; }
	uint32_t highest_frame_id() const { return highest_; }

	// Fills `out` with the window since the last call and starts a new one.
	// Returns false (leaving `out` alone) before any frame completed: there
	// is no highest frame to report against yet.
	bool take(uint64_t now_us, gdp::session::StreamStats *out);

	Snapshot snapshot() const;

private:
	uint32_t window_span() const;

	uint32_t stream_id_;

	// Ack window: bit i of completed_ is frame (highest_ - i).
	bool have_highest_ = false;
	uint32_t highest_ = 0;
	uint64_t completed_ = 0;
	// The first frame any datagram arrived for: older frames are never lost.
	bool have_first_ = false;
	uint32_t first_ = 0;

	// The newest frame whose datagrams are arriving, timed as a train.
	struct Current {
		bool active = false;
		uint32_t frame_id = 0;
		uint16_t slice_count = 0;
		std::vector<bool> seen;
		bool clean = true; // every datagram arrived exactly once so far
		uint32_t datagrams = 0;
		uint64_t first_us = 0;
		uint64_t last_us = 0;
		uint64_t bytes_after_first = 0;
	};
	Current current_;

	// The measurement window.
	uint64_t window_start_us_ = 0;
	uint64_t bytes_ = 0;
	int64_t delay_sum_us_ = 0;
	int32_t delay_min_us_ = 0;
	uint32_t delay_samples_ = 0;
	std::vector<Train> trains_;

	uint32_t decode_us_ = 0;
	uint32_t present_us_ = 0;

	Snapshot last_;
};

} // namespace gdpcore
