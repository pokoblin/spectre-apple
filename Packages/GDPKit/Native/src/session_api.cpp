// The C ABI in include/gdpcore.h over SessionClient and TestHost.
#include "gdpcore.h"

#include "session_client.hpp"
#include "test_host.hpp"

#include "gdp/file_transfer.hpp"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace {

std::vector<std::string> strings(const char *const *items, size_t count) {
	std::vector<std::string> out;
	for (size_t i = 0; i < count; i++) {
		if (items[i]) out.emplace_back(items[i]);
	}
	return out;
}

std::vector<const char *> c_strings(const std::vector<std::string> &items) {
	std::vector<const char *> out;
	for (const auto &s : items) out.push_back(s.c_str());
	return out;
}

gdpc_output to_c(const gdpcore::Output &o) {
	gdpc_output c{};
	c.stream_id = o.stream_id;
	c.width = o.width;
	c.height = o.height;
	c.refresh_mhz = o.refresh_mhz;
	c.scale = o.scale;
	c.matrix = o.matrix;
	c.range = o.range;
	c.primaries = o.primaries;
	c.transfer = o.transfer;
	c.bit_depth = o.bit_depth;
	c.chroma = o.chroma;
	return c;
}

std::vector<gdpc_output> to_c(const std::vector<gdpcore::Output> &outputs) {
	std::vector<gdpc_output> out;
	for (const auto &o : outputs) out.push_back(to_c(o));
	return out;
}

void copy_string(char *dst, size_t cap, const std::string &src) {
	std::snprintf(dst, cap, "%s", src.c_str());
}

std::string join(const std::vector<std::string> &items) {
	std::string out;
	for (const auto &s : items) out += (out.empty() ? "" : ",") + s;
	return out;
}

} // namespace

struct gdpc_session {
	explicit gdpc_session(const gdpc_session_callbacks &cb) : callbacks(cb), client(make_callbacks()) {}

	gdpc_session_callbacks callbacks;
	gdpcore::SessionClient client;

	gdpcore::SessionClient::Callbacks make_callbacks() {
		gdpcore::SessionClient::Callbacks cb;
		cb.accepted = [this](const gdpcore::AcceptInfo &info) {
			if (!callbacks.accepted) return;
			auto outputs = to_c(info.outputs);
			auto caps = c_strings(info.capabilities);
			gdpc_session_accept a{};
			a.codec = info.codec.c_str();
			a.outputs = outputs.data();
			a.output_count = outputs.size();
			a.bitrate_ceiling_bps = info.bitrate_ceiling_bps;
			a.has_audio = info.has_audio;
			a.audio_codec = info.audio_codec.c_str();
			a.audio_sample_rate_hz = info.audio_sample_rate_hz;
			a.audio_channels = info.audio_channels;
			a.audio_frame_ms = info.audio_frame_ms;
			a.has_microphone = info.has_microphone;
			a.microphone_codec = info.microphone_codec.c_str();
			a.microphone_sample_rate_hz = info.microphone_sample_rate_hz;
			a.microphone_channels = info.microphone_channels;
			a.microphone_frame_ms = info.microphone_frame_ms;
			a.capabilities = caps.data();
			a.capability_count = caps.size();
			a.network_profile = info.network_profile;
			a.via_gateway = info.via_gateway;
			a.encoder = info.encoder.c_str();
			a.host_user = info.host_user.c_str();
			a.host_name = info.host_name.c_str();
			callbacks.accepted(callbacks.ctx, &a);
		};
		cb.closed = [this](uint64_t code, const std::string &reason, bool cert, bool lost) {
			if (callbacks.closed) callbacks.closed(callbacks.ctx, code, reason.c_str(), cert, lost);
		};
		cb.displays_changed = [this](const std::vector<gdpcore::Output> &outputs) {
			if (!callbacks.displays_changed) return;
			auto c = to_c(outputs);
			callbacks.displays_changed(callbacks.ctx, c.data(), c.size());
		};
		cb.video_frame = [this](const gdpcore::VideoFrame &f) {
			if (!callbacks.video_frame) return false;
			gdpc_video_frame c{};
			c.stream_id = f.stream_id;
			c.frame_id = f.frame_id;
			c.keyframe = f.keyframe;
			c.pts = f.pts;
			c.data = f.data;
			c.len = f.len;
			return callbacks.video_frame(callbacks.ctx, &c);
		};
		cb.audio_packet = [this](uint16_t seq, uint32_t pts, const uint8_t *opus, size_t len) {
			if (callbacks.audio_packet) callbacks.audio_packet(callbacks.ctx, seq, pts, opus, len);
		};
		cb.cursor_shape = [this](uint32_t w, uint32_t h, uint32_t hx, uint32_t hy, const uint8_t *bgra) {
			if (callbacks.cursor_shape) callbacks.cursor_shape(callbacks.ctx, w, h, hx, hy, bgra);
		};
		cb.cursor_position = [this](double x, double y) {
			if (callbacks.cursor_position) callbacks.cursor_position(callbacks.ctx, x, y);
		};
		cb.network_profile_changed = [this](int32_t p) {
			if (callbacks.network_profile_changed) callbacks.network_profile_changed(callbacks.ctx, p);
		};
		cb.diagnostics_requested = [this] {
			if (callbacks.diagnostics_requested) callbacks.diagnostics_requested(callbacks.ctx);
		};
		cb.clipboard_text = [this](const uint8_t *text, size_t len) {
			if (callbacks.clipboard_text) callbacks.clipboard_text(callbacks.ctx, text, len);
		};
		cb.file_accepted = [this](uint64_t id) {
			if (callbacks.file_accepted) callbacks.file_accepted(callbacks.ctx, id);
		};
		cb.file_progress = [this](uint64_t id, uint64_t acked) {
			if (callbacks.file_progress) callbacks.file_progress(callbacks.ctx, id, acked);
		};
		cb.file_list = [this](uint64_t list_id, const std::vector<gdpcore::FileListEntry> &files) {
			if (!callbacks.file_list) return;
			std::vector<gdpc_file_list_entry> c;
			c.reserve(files.size());
			for (const auto &f : files) c.push_back({f.name.c_str(), f.size, f.modified_unix_ms, f.directory});
			callbacks.file_list(callbacks.ctx, list_id, c.data(), c.size());
		};
		cb.file_sending = [this](uint64_t id, const std::string &name, uint64_t size, int64_t modified) {
			if (callbacks.file_sending) callbacks.file_sending(callbacks.ctx, id, name.c_str(), size, modified);
		};
		cb.file_data = [this](uint64_t id, const uint8_t *data, size_t len) {
			if (callbacks.file_data) callbacks.file_data(callbacks.ctx, id, data, len);
		};
		cb.file_finished = [this](uint64_t id, gdpcore::FileOutcome outcome, int32_t error, const std::string &name) {
			if (!callbacks.file_finished) return;
			bool saved = outcome == gdpcore::FileOutcome::kSaved;
			callbacks.file_finished(callbacks.ctx, id, static_cast<int32_t>(outcome), error, saved ? name.c_str() : nullptr);
		};
		return cb;
	}
};

struct gdpc_test_host {
	gdpcore::TestHost host;
};

extern "C" {

// --- Session ---

gdpc_session *gdpc_session_create(const gdpc_session_callbacks *callbacks) {
	return new gdpc_session(callbacks ? *callbacks : gdpc_session_callbacks{});
}

void gdpc_session_destroy(gdpc_session *session) { delete session; }

bool gdpc_session_connect(gdpc_session *session, const gdpc_session_config *c, char *error, size_t error_cap) {
	gdpcore::SessionClient::Config config;
	config.host = c->host ? c->host : "";
	config.port = c->port;
	config.token = c->token ? c->token : "";
	config.cert_sha256 = c->cert_sha256 ? c->cert_sha256 : "";
	config.codecs = strings(c->codecs, c->codec_count);
	config.capabilities = strings(c->capabilities, c->capability_count);
	config.decoders = strings(c->decoders, c->decoder_count);
	config.display_width = c->display_width;
	config.display_height = c->display_height;
	config.display_refresh_mhz = c->display_refresh_mhz;
	config.display_scale = c->display_scale;
	config.take_over = c->take_over;
	config.network_profile = c->network_profile;
	config.drop_until_keyframe_after_loss = c->drop_until_keyframe_after_loss;
	config.file_reply_timeout_ms = c->file_reply_timeout_ms;
	std::string err;
	bool ok = session->client.start(config, &err);
	if (!ok && error && error_cap) copy_string(error, error_cap, err);
	return ok;
}

int gdpc_session_notify_fd(const gdpc_session *session) { return session->client.notify_fd(); }
void gdpc_session_dispatch(gdpc_session *session) { session->client.dispatch(); }
void gdpc_session_close(gdpc_session *session) { session->client.close(); }
bool gdpc_session_established(const gdpc_session *session) { return session->client.established(); }
void gdpc_session_send_stats_report(gdpc_session *session) { session->client.send_stats_report(); }

void gdpc_session_record_frame_timing(gdpc_session *session, uint32_t decode_us, uint32_t present_us) {
	session->client.record_frame_timing(decode_us, present_us);
}

void gdpc_session_mark_frame_discarded(gdpc_session *session, uint8_t stream_id, uint32_t frame_id) {
	session->client.mark_frame_discarded(stream_id, frame_id);
}

void gdpc_session_request_keyframe(gdpc_session *session, uint32_t stream_id) {
	session->client.request_keyframe(stream_id);
}

void gdpc_session_request_resolution(gdpc_session *session, uint32_t stream_id, uint32_t width, uint32_t height) {
	session->client.request_resolution(stream_id, width, height);
}

void gdpc_session_send_logout(gdpc_session *session) { session->client.send_logout(); }

void gdpc_session_send_diagnostics_report(gdpc_session *session, const uint8_t *text, size_t len) {
	session->client.send_diagnostics_report(text, len);
}

void gdpc_session_send_clipboard_text(gdpc_session *session, const uint8_t *text, size_t len) {
	session->client.send_clipboard_text(text, len);
}

uint64_t gdpc_session_offer_file(gdpc_session *session, const char *name, uint64_t size, int64_t modified_unix_ms) {
	return name ? session->client.offer_file(name, size, modified_unix_ms) : 0;
}

bool gdpc_session_send_file_data(gdpc_session *session, uint64_t id, const uint8_t *data, size_t len) {
	return session->client.send_file_data(id, data, len);
}

void gdpc_session_cancel_file(gdpc_session *session, uint64_t id) { session->client.cancel_file(id); }

uint64_t gdpc_session_request_file(gdpc_session *session, uint64_t list_id, uint32_t index) {
	return session->client.request_file(list_id, index);
}

void gdpc_session_consume_file_data(gdpc_session *session, uint64_t id, size_t len) {
	session->client.consume_file_data(id, len);
}

bool gdpc_valid_file_name(const char *name) { return name && gdp::valid_file_name(name); }

void gdpc_session_send_key(gdpc_session *session, uint32_t hid_usage, bool pressed) {
	session->client.send_key(hid_usage, pressed);
}

void gdpc_session_send_pointer_motion(gdpc_session *session, double dx, double dy, bool absolute) {
	session->client.send_pointer_motion(dx, dy, absolute);
}

void gdpc_session_send_pointer_button(gdpc_session *session, uint32_t button, bool pressed) {
	session->client.send_pointer_button(button, pressed);
}

void gdpc_session_send_pointer_axis(gdpc_session *session, double horizontal, double vertical) {
	session->client.send_pointer_axis(horizontal, vertical);
}

void gdpc_session_send_touch(gdpc_session *session, uint32_t touch_id, int32_t phase, double x, double y) {
	session->client.send_touch(touch_id, phase, x, y);
}

void gdpc_session_send_gamepad_connect(gdpc_session *session, uint32_t slot, const char *name) {
	session->client.send_gamepad_connect(slot, name ? name : "");
}

void gdpc_session_send_gamepad_state(gdpc_session *session, uint32_t slot, const float *axes, const bool *buttons) {
	session->client.send_gamepad_state(slot, axes, buttons);
}

void gdpc_session_send_gamepad_disconnect(gdpc_session *session, uint32_t slot) {
	session->client.send_gamepad_disconnect(slot);
}

bool gdpc_session_send_microphone(gdpc_session *session, const uint8_t *opus, size_t len) {
	return session->client.send_microphone(opus, len);
}

void gdpc_session_get_link_stats(const gdpc_session *session, gdpc_session_link_stats *out) {
	auto s = session->client.link_stats();
	*out = gdpc_session_link_stats{};
	out->rtt_us = s.rtt_us;
	out->upstream_rtt_us = s.upstream_rtt_us;
	out->path_mtu = s.path_mtu;
	out->max_datagram_size = s.max_datagram_size;
	out->stats_reports_sent = s.stats_reports_sent;
	out->frames_delivered = s.frames_delivered;
	out->frames_dropped = s.frames_dropped;
	out->has_frames = s.video.has_frames;
	out->highest_frame_id = s.video.highest_frame_id;
	out->loss_bitmap = s.video.loss_bitmap;
	out->window_span = s.video.window_span;
	out->delay_min_us = s.video.last_delay_min_us;
	out->delay_avg_us = s.video.last_delay_avg_us;
	out->delay_samples = s.video.last_delay_samples;
	out->bytes_last_window = s.video.last_bytes;
	out->last_window_us = s.video.last_interval_us;
	out->microphone_sent = s.microphone_sent;
	out->microphone_dropped = s.microphone_dropped;
}

// --- Test host ---

gdpc_test_host *gdpc_test_host_create(const gdpc_test_host_config *c, char *error, size_t error_cap) {
	gdpcore::TestHost::Config config;
	if (c->scratch_dir) config.scratch_dir = c->scratch_dir;
	if (c->token) config.token = c->token;
	if (c->codec_count) config.codecs = strings(c->codecs, c->codec_count);
	config.capabilities = strings(c->capabilities, c->capability_count);
	if (c->width) config.width = c->width;
	if (c->height) config.height = c->height;
	config.audio = c->audio;
	if (c->audio_codec) config.audio_codec = c->audio_codec;
	if (c->audio_sample_rate_hz) config.audio_sample_rate_hz = c->audio_sample_rate_hz;
	if (c->audio_channels) config.audio_channels = c->audio_channels;
	if (c->audio_frame_ms) config.audio_frame_ms = c->audio_frame_ms;
	if (c->microphone_codec) config.microphone_codec = c->microphone_codec;
	if (c->microphone_sample_rate_hz) config.microphone_sample_rate_hz = c->microphone_sample_rate_hz;
	if (c->microphone_channels) config.microphone_channels = c->microphone_channels;
	if (c->microphone_frame_ms) config.microphone_frame_ms = c->microphone_frame_ms;
	if (c->force_codec) config.force_codec = c->force_codec;
	config.refuse_code = c->refuse_code;
	if (c->reject_reason) config.reject_reason = c->reject_reason;
	config.ping_before_accept = c->ping_before_accept;
	config.first_frame_id = c->first_frame_id;
	config.simulate_pointer = c->simulate_pointer;
	if (c->clipboard) config.clipboard = c->clipboard;
	config.file_refuse = c->file_refuse;
	config.file_fail_after = c->file_fail_after;
	config.file_ignore_offers = c->file_ignore_offers;
	if (c->file_directory) config.file_directory = c->file_directory;
	config.host_files = strings(c->host_files, c->host_file_count);

	auto *h = new gdpc_test_host;
	std::string err;
	if (!h->host.start(config, &err)) {
		if (error && error_cap) copy_string(error, error_cap, err);
		delete h;
		return nullptr;
	}
	return h;
}

void gdpc_test_host_destroy(gdpc_test_host *host) { delete host; }
uint16_t gdpc_test_host_port(const gdpc_test_host *host) { return host->host.port(); }

void gdpc_test_host_cert_sha256(const gdpc_test_host *host, char out[GDPC_SHA256_HEX_LEN + 1]) {
	copy_string(out, GDPC_SHA256_HEX_LEN + 1, host->host.cert_sha256());
}

void gdpc_test_host_send_video_frame(gdpc_test_host *host, const uint8_t *data, size_t len, bool keyframe,
	const uint16_t *drop_slices, size_t drop_count, size_t max_payload) {
	host->host.send_video_frame(std::vector<uint8_t>(data, data + len), keyframe,
		std::vector<uint16_t>(drop_slices, drop_slices + drop_count), max_payload);
}

void gdpc_test_host_send_audio(gdpc_test_host *host, const uint8_t *opus, size_t len) {
	host->host.send_audio(std::vector<uint8_t>(opus, opus + len));
}

void gdpc_test_host_send_audio_packet(gdpc_test_host *host, uint16_t seq, uint32_t pts, const uint8_t *opus,
	size_t len) {
	host->host.send_audio_packet(seq, pts, std::vector<uint8_t>(opus, opus + len));
}

void gdpc_test_host_send_ping(gdpc_test_host *host, uint64_t nonce) { host->host.send_ping(nonce); }

void gdpc_test_host_send_cursor_shape(gdpc_test_host *host, uint32_t width, uint32_t height, uint32_t hotspot_x,
	uint32_t hotspot_y, const uint8_t *argb, size_t len) {
	host->host.send_cursor_shape(width, height, hotspot_x, hotspot_y, std::vector<uint8_t>(argb, argb + len));
}

void gdpc_test_host_send_cursor_position(gdpc_test_host *host, double x, double y) {
	host->host.send_cursor_position(x, y);
}

void gdpc_test_host_send_displays_changed(gdpc_test_host *host, uint32_t width, uint32_t height) {
	host->host.send_displays_changed(width, height);
}

void gdpc_test_host_send_network_profile(gdpc_test_host *host, int32_t profile) {
	host->host.send_network_profile(profile);
}

void gdpc_test_host_send_gateway_path(gdpc_test_host *host, uint32_t upstream_rtt_us) {
	host->host.send_gateway_path(upstream_rtt_us);
}

void gdpc_test_host_send_diagnostics_request(gdpc_test_host *host) { host->host.send_diagnostics_request(); }

void gdpc_test_host_send_file_list(gdpc_test_host *host, const char *const *paths, size_t count) {
	host->host.send_file_list(strings(paths, count));
}

void gdpc_test_host_send_clipboard(gdpc_test_host *host, const char *mime_type, const uint8_t *data, size_t len) {
	host->host.send_clipboard(mime_type ? mime_type : "", std::string(reinterpret_cast<const char *>(data), len));
}
void gdpc_test_host_close(gdpc_test_host *host, uint64_t code) { host->host.close(code); }
bool gdpc_test_host_take_keyframe_wanted(gdpc_test_host *host) { return host->host.take_keyframe_wanted(); }

void gdpc_test_host_get_observed(const gdpc_test_host *host, gdpc_test_host_observed *out) {
	auto o = host->host.observed();
	*out = gdpc_test_host_observed{};
	out->connected = o.connected;
	out->hello_received = o.hello_received;
	copy_string(out->token, sizeof(out->token), o.token);
	copy_string(out->codecs, sizeof(out->codecs), join(o.codecs));
	copy_string(out->capabilities, sizeof(out->capabilities), join(o.capabilities));
	copy_string(out->decoders, sizeof(out->decoders), join(o.decoders));
	out->take_over = o.take_over;
	out->via_gateway = o.via_gateway;
	out->network_profile = o.network_profile;
	out->requested_width = o.requested_width;
	out->requested_height = o.requested_height;
	out->accepted = o.accepted;
	copy_string(out->accepted_codec, sizeof(out->accepted_codec), o.accepted_codec);
	out->closed = o.closed;
	out->close_code = o.close_code;

	out->stats_reports = o.stats_reports;
	out->last_rtt_us = o.last_stats.rtt_us;
	out->last_has_stream = o.last_stats.has_stream;
	out->last_highest_frame_id = o.last_stats.highest_frame_id_acked;
	out->last_loss_bitmap = o.last_stats.loss_bitmap;
	out->last_decode_us = o.last_stats.decode_us;
	out->last_present_us = o.last_stats.present_us;
	out->last_interval_us = o.last_stats.interval_us;
	out->last_bytes_received = o.last_stats.bytes_received;
	out->last_delay_min_us = o.last_stats.delay_min_us;
	out->last_delay_avg_us = o.last_stats.delay_avg_us;
	out->last_delay_samples = o.last_stats.delay_samples;
	out->last_trains = o.last_stats.trains;
	out->last_train_datagrams = o.last_stats.train_datagrams;
	out->last_train_bytes = o.last_stats.train_bytes;
	out->bytes_reported = o.bytes_reported;
	out->lost_frame_count = static_cast<uint32_t>(o.lost_frame_ids.size());
	for (size_t i = 0; i < std::min<size_t>(o.lost_frame_ids.size(), 64); i++) out->lost_frame_ids[i] = o.lost_frame_ids[i];

	out->keyframe_requests = o.keyframe_requests;
	out->resolution_requests = static_cast<uint32_t>(o.resolution_requests.size());
	if (!o.resolution_requests.empty()) {
		out->last_resolution_width = o.resolution_requests.back().first;
		out->last_resolution_height = o.resolution_requests.back().second;
	}
	out->logout_requested = o.logout_requested;
	out->pongs = o.pongs;
	out->last_pong_nonce = o.last_pong_nonce;
	out->diagnostics_report_len = o.diagnostics_report.size();

	out->key_events = static_cast<uint32_t>(o.keys.size());
	if (!o.keys.empty()) {
		out->last_key_usage = o.keys.back().first;
		out->last_key_pressed = o.keys.back().second;
	}
	out->pointer_motions = o.pointer_motions;
	out->last_motion_x = o.last_motion_x;
	out->last_motion_y = o.last_motion_y;
	out->last_motion_absolute = o.last_motion_absolute;
	out->button_events = static_cast<uint32_t>(o.buttons.size());
	if (!o.buttons.empty()) {
		out->last_button = o.buttons.back().first;
		out->last_button_pressed = o.buttons.back().second;
	}
	out->axis_vertical_sum = o.axis_vertical_sum;
	out->axis_horizontal_sum = o.axis_horizontal_sum;
	out->input_event_count = static_cast<uint32_t>(o.inputs.size());
	out->viewer_closed = o.viewer_closed;
	out->viewer_close_code = o.viewer_close_code;
	copy_string(out->viewer_close_reason, sizeof(out->viewer_close_reason), o.viewer_close_reason);
	out->pointer_x = o.pointer_x;
	out->pointer_y = o.pointer_y;
	out->cursor_positions_sent = o.cursor_positions_sent;
	out->clipboard_messages = o.clipboard_messages;
	copy_string(out->last_clipboard_mime, sizeof(out->last_clipboard_mime), o.last_clipboard_mime);
	out->files_offered = o.files_offered;
	out->files_saved = o.files_saved;
	out->files_refused = o.files_refused;
	out->files_failed = o.files_failed;
	out->files_cancelled = o.files_cancelled;
	out->file_streams_open = o.file_streams_open;
	copy_string(out->last_file_name, sizeof(out->last_file_name), o.last_file_name);
	out->file_lists_sent = o.file_lists_sent;
	out->file_list_id = o.file_list_id;
	out->files_requested = o.files_requested;
	out->files_served = o.files_served;
	out->file_requests_refused = o.file_requests_refused;
	out->touches = o.touches;
	out->input_before_accept = o.input_before_accept;

	out->frames_sent = o.frames_sent;
	out->next_frame_id = o.next_frame_id;
	out->max_datagram_size = o.max_datagram_size;
	out->microphone_packets = o.microphone_packets;
	out->microphone_bytes = o.microphone_bytes;
	out->microphone_dropped = o.microphone_dropped;
}

size_t gdpc_test_host_input_events(const gdpc_test_host *host, size_t first, gdpc_test_input_event *out, size_t cap) {
	auto o = host->host.observed();
	size_t n = 0;
	for (size_t i = first; i < o.inputs.size() && n < cap; i++, n++) {
		const auto &e = o.inputs[i];
		out[n] = gdpc_test_input_event{static_cast<int32_t>(e.kind), e.code, e.pressed, e.x, e.y, e.absolute, e.phase,
			e.axis_count, e.button_count, {}, e.buttons, {}};
		std::copy(std::begin(e.axes), std::end(e.axes), out[n].axes);
		copy_string(out[n].name, sizeof(out[n].name), e.name);
	}
	return n;
}

bool gdpc_test_host_latest_microphone_packet(const gdpc_test_host *host, uint16_t *seq, uint32_t *pts, uint8_t *opus,
	size_t cap, size_t *len) {
	gdpcore::TestHost::MicrophonePacket p;
	if (!host->host.latest_microphone_packet(&p)) return false;
	*seq = p.seq;
	*pts = p.pts;
	*len = p.opus.size();
	std::copy(p.opus.begin(), p.opus.begin() + static_cast<ptrdiff_t>(std::min(cap, p.opus.size())), opus);
	return true;
}

bool gdpc_test_host_microphone_packet(const gdpc_test_host *host, size_t index, uint16_t *seq, uint32_t *pts,
	uint8_t *opus, size_t cap, size_t *len) {
	gdpcore::TestHost::MicrophonePacket p;
	if (!host->host.microphone_packet(index, &p)) return false;
	*seq = p.seq;
	*pts = p.pts;
	*len = p.opus.size();
	std::copy(p.opus.begin(), p.opus.begin() + static_cast<ptrdiff_t>(std::min(cap, p.opus.size())), opus);
	return true;
}

bool gdpc_test_host_received_file(const gdpc_test_host *host, size_t index, gdpc_test_host_file *info, uint8_t *data,
	size_t cap) {
	gdpcore::TestHost::ReceivedFile f;
	if (!host->host.received_file(index, &f)) return false;
	if (info) {
		copy_string(info->name, sizeof(info->name), f.name);
		copy_string(info->saved_name, sizeof(info->saved_name), f.saved_name);
		info->modified_unix_ms = f.modified_unix_ms;
		info->size = f.size;
		copy_string(info->path, sizeof(info->path), f.path);
	}
	if (data) std::copy_n(f.data.begin(), std::min(cap, f.data.size()), data);
	return true;
}

size_t gdpc_test_host_last_clipboard(const gdpc_test_host *host, uint8_t *out, size_t cap) {
	auto o = host->host.observed();
	std::copy_n(o.last_clipboard.begin(), std::min(cap, o.last_clipboard.size()), out);
	return o.last_clipboard.size();
}

} // extern "C"
