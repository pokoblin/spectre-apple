#include "receive_stats.hpp"

#include "session.pb.h"

#include <algorithm>
#include <limits>

namespace gdpcore {

namespace {

// gdp-spec.md §11: 32-bit values compare only by their wrapped difference.
int32_t diff32(uint32_t a, uint32_t b) {
	return static_cast<int32_t>(a - b);
}

} // namespace

void StreamReceiveStats::on_datagram(const gdp::VideoDatagramHeader &h, size_t datagram_len, uint64_t arrival_us,
	uint64_t session_epoch_us) {
	bytes_ += datagram_len;
	if (!have_first_) {
		have_first_ = true;
		first_ = h.frame_id;
	}

	if (!current_.active || diff32(h.frame_id, current_.frame_id) > 0) {
		// The first datagram to arrive of a frame newer than any seen: its
		// one-way delay on our session clock, against the frame's pts.
		uint32_t arrival_session = static_cast<uint32_t>(arrival_us - session_epoch_us);
		int32_t delay = diff32(arrival_session, h.pts);
		if (delay_samples_ == 0 || delay < delay_min_us_) delay_min_us_ = delay;
		delay_sum_us_ += delay;
		delay_samples_++;

		current_ = Current{};
		current_.active = true;
		current_.frame_id = h.frame_id;
		current_.slice_count = h.slice_count;
		current_.seen.assign(h.slice_count, false);
		current_.first_us = arrival_us;
		current_.last_us = arrival_us;
	} else if (h.frame_id != current_.frame_id) {
		return; // a straggler of an older frame: not part of any train
	} else {
		current_.last_us = arrival_us;
		current_.bytes_after_first += datagram_len;
	}

	current_.datagrams++;
	if (h.slice_count != current_.slice_count || h.slice_idx >= current_.seen.size() ||
		current_.seen[h.slice_idx]) {
		current_.clean = false;
	} else {
		current_.seen[h.slice_idx] = true;
	}
}

void StreamReceiveStats::on_frame_completed(uint32_t frame_id) {
	if (!have_highest_) {
		have_highest_ = true;
		highest_ = frame_id;
		completed_ = 1;
	} else {
		int32_t d = diff32(frame_id, highest_);
		if (d > 0) {
			completed_ = d >= 64 ? 0 : completed_ << d;
			completed_ |= 1;
			highest_ = frame_id;
		} else if (-d < 64) {
			completed_ |= uint64_t(1) << -d;
		}
	}

	if (current_.active && current_.frame_id == frame_id && current_.clean &&
		current_.datagrams == current_.slice_count && current_.slice_count >= kMinTrainDatagrams) {
		Train t;
		t.frame_id = frame_id;
		t.datagrams = current_.datagrams;
		t.bytes = static_cast<uint32_t>(std::min<uint64_t>(current_.bytes_after_first, UINT32_MAX));
		t.span_us = static_cast<uint32_t>(std::min<uint64_t>(current_.last_us - current_.first_us, UINT32_MAX));
		if (trains_.size() == kMaxTrainsPerReport) {
			trains_.erase(trains_.begin()); // keep the most recent
		}
		trains_.push_back(t);
	}
}

void StreamReceiveStats::on_frame_discarded(uint32_t frame_id) {
	if (!have_highest_) return;
	int32_t d = diff32(highest_, frame_id);
	if (d >= 0 && d < 64) {
		completed_ &= ~(uint64_t(1) << d);
	}
}

void StreamReceiveStats::record_timing(uint32_t decode_us, uint32_t present_us) {
	decode_us_ = decode_us;
	present_us_ = present_us;
}

uint32_t StreamReceiveStats::window_span() const {
	if (!have_highest_ || !have_first_) return 0;
	int32_t span = diff32(highest_, first_) + 1;
	return static_cast<uint32_t>(std::clamp(span, 0, 64));
}

uint64_t StreamReceiveStats::loss_bitmap() const {
	uint32_t span = window_span();
	uint64_t mask = span >= 64 ? ~uint64_t(0) : (uint64_t(1) << span) - 1;
	return ~completed_ & mask;
}

bool StreamReceiveStats::take(uint64_t now_us, gdp::session::StreamStats *out) {
	if (!have_highest_) return false;
	uint32_t interval = static_cast<uint32_t>(std::min<uint64_t>(now_us - window_start_us_, UINT32_MAX));

	out->set_stream_id(stream_id_);
	out->set_highest_frame_id_acked(highest_);
	out->set_loss_bitmap(loss_bitmap());
	out->set_decode_us(decode_us_);
	out->set_present_us(present_us_);
	// A client that measures never reports a 0 interval (§7.5).
	out->set_interval_us(std::max<uint32_t>(interval, 1));
	out->set_bytes_received(bytes_);
	int32_t avg = delay_samples_ ? static_cast<int32_t>(delay_sum_us_ / delay_samples_) : 0;
	out->set_delay_min_us(delay_samples_ ? delay_min_us_ : 0);
	out->set_delay_avg_us(avg);
	out->set_delay_samples(delay_samples_);
	for (const Train &t : trains_) {
		auto *ft = out->add_trains();
		ft->set_frame_id(t.frame_id);
		ft->set_datagrams(t.datagrams);
		ft->set_bytes(t.bytes);
		ft->set_span_us(t.span_us);
	}

	last_.last_delay_min_us = delay_samples_ ? delay_min_us_ : 0;
	last_.last_delay_avg_us = avg;
	last_.last_delay_samples = delay_samples_;
	last_.last_bytes = bytes_;
	last_.last_interval_us = interval;

	window_start_us_ = now_us;
	bytes_ = 0;
	delay_sum_us_ = 0;
	delay_min_us_ = 0;
	delay_samples_ = 0;
	trains_.clear();
	return true;
}

StreamReceiveStats::Snapshot StreamReceiveStats::snapshot() const {
	Snapshot s = last_;
	s.has_frames = have_highest_;
	s.highest_frame_id = highest_;
	s.loss_bitmap = loss_bitmap();
	s.window_span = window_span();
	return s;
}

} // namespace gdpcore
