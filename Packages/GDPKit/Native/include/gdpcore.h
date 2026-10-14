// GDPCore: the C ABI over libgdp (third_party/ghost/libgdp) that Swift sees.
//
// libgdp is C++ (std::function callbacks, abstract classes, protobuf
// messages) and stays behind this header: Swift imports plain C types,
// opaque handles and function-pointer callbacks with a `ctx` pointer, and
// never needs C++ interop. See docs/prototype-findings.md, risk 1.
//
// Conventions:
// - Every `gdpc_*_create()` has a matching `gdpc_*_destroy()`; handles are
//   not thread-safe unless a function says so.
// - Byte pointers handed to callbacks are valid only for the duration of the
//   callback.
// - Section references (§) are to third_party/ghost/docs/spec/gdp-spec.md.
#ifndef GDPCORE_H
#define GDPCORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Protocol constants (gdp/version.hpp, gdp/framing.hpp, gdp/datagram.hpp)

// The ALPN token, "gdp/1" (§2.1). Static storage.
const char *gdpc_alpn(void);
uint32_t gdpc_wire_version(void);

#define GDPC_MAX_FRAME_SIZE (1u << 20)        // §3.1
#define GDPC_FRAME_LENGTH_PREFIX_SIZE 4u      // §3.1
#define GDPC_VIDEO_HEADER_SIZE 16u            // §9.1, after the channel byte
#define GDPC_FALLBACK_DATAGRAM_PAYLOAD 1100u  // §9.2
#define GDPC_MAX_SLICE_PAYLOAD 1500u

// ---------------------------------------------------------------------------
// Certificate fingerprints (gdp/cert_fingerprint.hpp, §2.3)

#define GDPC_SHA256_HEX_LEN 64u        // lowercase hex, no separators
#define GDPC_FINGERPRINT_DISPLAY_LEN 95u // "AB:CD:...", 32 pairs + 31 colons

void gdpc_sha256(const uint8_t *data, size_t len, uint8_t out[32]);
// Writes GDPC_SHA256_HEX_LEN digits and a NUL to `out`.
void gdpc_sha256_hex(const uint8_t *data, size_t len, char out[GDPC_SHA256_HEX_LEN + 1]);
bool gdpc_is_sha256_hex(const char *s);
// The form shown to a person. Returns false (writing an empty string) if
// `sha256_hex` is not a gdpc_is_sha256_hex() value.
bool gdpc_format_fingerprint(const char *sha256_hex, char out[GDPC_FINGERPRINT_DISPLAY_LEN + 1]);

// ---------------------------------------------------------------------------
// Control-stream framing (gdp/framing.hpp, §3.1, §6.1)
//
// The session layer frames and parses ControlEnvelopes in C++; these entry
// points expose the same libgdp framing to Swift for tests and tools. A
// parsed envelope is reported by its oneof case (the ControlEnvelope field
// number, e.g. 5 = ping, 6 = pong; 0 = unset) plus the fields of the small
// messages that need no further structure.

typedef enum {
    GDPC_CONTROL_MSG_UNSET = 0,
    GDPC_CONTROL_MSG_HELLO = 1,
    GDPC_CONTROL_MSG_ACCEPT = 2,
    GDPC_CONTROL_MSG_REJECT = 3,
    GDPC_CONTROL_MSG_STATS = 4,
    GDPC_CONTROL_MSG_PING = 5,
    GDPC_CONTROL_MSG_PONG = 6,
    GDPC_CONTROL_MSG_KEYFRAME_REQUEST = 12,
} gdpc_control_msg;

typedef struct {
    int32_t msg_case;      // gdpc_control_msg, or any other ControlEnvelope field number
    uint64_t nonce;        // ping / pong
    uint32_t stream_id;    // keyframe_request
    size_t encoded_size;   // the envelope's protobuf size, without the length prefix
} gdpc_control_frame;

// Encodes one length-prefixed ControlEnvelope into `out`. Returns the bytes
// written, or 0 if `cap` is too small.
size_t gdpc_encode_ping(uint64_t nonce, uint8_t *out, size_t cap);
size_t gdpc_encode_pong(uint64_t nonce, uint8_t *out, size_t cap);
size_t gdpc_encode_keyframe_request(uint32_t stream_id, uint8_t *out, size_t cap);

typedef enum {
    GDPC_FEED_OK = 0,        // every complete frame was delivered; the rest waits for more bytes
    GDPC_FEED_TOO_LARGE = 1, // a length prefix exceeded the reader's limit: close with error_code
    GDPC_FEED_MALFORMED = 2, // a frame did not parse as a ControlEnvelope: close with error_code
} gdpc_feed_result;

typedef struct gdpc_control_reader gdpc_control_reader;
typedef void (*gdpc_control_frame_fn)(void *ctx, const gdpc_control_frame *frame);

gdpc_control_reader *gdpc_control_reader_create(void);
void gdpc_control_reader_destroy(gdpc_control_reader *reader);
// Lowers the accepted frame size (§6.3's pre-authentication cap); clamped to GDPC_MAX_FRAME_SIZE.
void gdpc_control_reader_set_max_frame_size(gdpc_control_reader *reader, size_t max);
// Feeds bytes as a stream delivers them, in any chunking, and calls
// `on_frame` once per complete frame.
gdpc_feed_result gdpc_control_reader_feed(gdpc_control_reader *reader, const uint8_t *data, size_t len,
    gdpc_control_frame_fn on_frame, void *ctx);
// The §12 error code for the last failed feed (FRAME_TOO_LARGE / MALFORMED_FRAME), 0 otherwise.
uint64_t gdpc_control_reader_error_code(const gdpc_control_reader *reader);

// ---------------------------------------------------------------------------
// Video datagrams (gdp/datagram.hpp, gdp/video_reassembler.hpp, §9)

typedef struct {
    uint8_t stream_id;
    uint32_t frame_id;
    uint16_t slice_idx;
    uint16_t slice_count;
    bool keyframe;
    uint32_t pts;          // host session clock, µs (§11)
    uint32_t host_latency_us; // 0 = not reported
} gdpc_video_header;

// Video slice payload for a connection whose largest datagram is `max_datagram_size`.
size_t gdpc_slice_payload_for(size_t max_datagram_size);

// Parses one whole datagram (channel byte + header + payload). On success the
// payload is `data[*payload_offset ..< *payload_offset + *payload_len]`.
bool gdpc_video_datagram_decode(const uint8_t *data, size_t len, gdpc_video_header *out, size_t *payload_offset,
    size_t *payload_len);

// Splits one coded frame into datagrams (the host's side; for tests and
// tools). `header` supplies stream_id/frame_id/keyframe/pts/host_latency_us.
// `send` returning false stops early; the function then returns false.
typedef bool (*gdpc_datagram_fn)(void *ctx, const uint8_t *datagram, size_t len);
bool gdpc_slice_video_frame(const gdpc_video_header *header, const uint8_t *data, size_t len, size_t max_payload,
    gdpc_datagram_fn send, void *ctx);

typedef struct {
    uint8_t stream_id;
    uint32_t frame_id;
    bool keyframe;
    uint32_t pts;
    const uint8_t *data;
    size_t len;
} gdpc_video_frame;

typedef struct gdpc_video_reassembler gdpc_video_reassembler;
typedef void (*gdpc_video_frame_fn)(void *ctx, const gdpc_video_frame *frame);

gdpc_video_reassembler *gdpc_video_reassembler_create(void);
void gdpc_video_reassembler_destroy(gdpc_video_reassembler *reassembler);
// Feeds one whole video datagram. Calls `on_frame` (and returns true) when
// this slice completed a frame; returns false otherwise, including for a
// datagram that is not a well-formed video datagram.
bool gdpc_video_reassembler_push(gdpc_video_reassembler *reassembler, const uint8_t *datagram, size_t len,
    gdpc_video_frame_fn on_frame, void *ctx);

// ---------------------------------------------------------------------------
// Self-test: a real QUIC connection over loopback through libgdp's
// Transport (ngtcp2 + OpenSSL), both ends in this process. Proves the
// static libraries work on the platform at hand (macOS, iOS, simulator).
//
// Generates a throwaway self-signed certificate in `scratch_dir` (a writable
// directory, e.g. NSTemporaryDirectory()), listens on 127.0.0.1, connects,
// checks the client saw exactly that certificate's fingerprint, round-trips
// a framed Ping/Pong on the control stream, and sends one video frame from
// server to client as sliced datagrams that the client reassembles. Blocks
// for up to `timeout_ms`.

typedef struct {
    bool ok;
    char error[256];                               // why not, when !ok
    char cert_sha256[GDPC_SHA256_HEX_LEN + 1];     // what the client saw
    uint16_t port;
    uint32_t rtt_us;                               // ngtcp2's smoothed RTT at the end
    uint16_t max_datagram_size;                    // after path MTU discovery
    uint32_t datagrams_received;
    double handshake_ms;
    double total_ms;
} gdpc_selftest_result;

void gdpc_selftest_quic_loopback(const char *scratch_dir, int timeout_ms, gdpc_selftest_result *out);

// ---------------------------------------------------------------------------
// Session (§6-§11): the client end of a session connection.
//
// Not thread-safe: create, call and destroy a session from one serial queue,
// and call gdpc_session_dispatch() on it whenever gdpc_session_notify_fd()
// becomes readable (and periodically). Every callback fires from
// gdpc_session_dispatch() on that queue. Don't destroy the session from
// inside a callback. Pointers passed to callbacks are valid only during them.

typedef struct gdpc_session gdpc_session;

typedef enum {
    GDPC_NETWORK_PROFILE_AUTO = 0,
    GDPC_NETWORK_PROFILE_LAN = 1,
    GDPC_NETWORK_PROFILE_INTERNET = 2,
    GDPC_NETWORK_PROFILE_MOBILE = 3,
} gdpc_network_profile;

typedef struct {
    const char *host;
    uint16_t port;
    const char *token;
    const char *cert_sha256;           // the only certificate accepted (§2.3)
    const char *const *codecs;         // preference order (§6.6)
    size_t codec_count;
    const char *const *capabilities;   // §6.7; only what the client implements
    size_t capability_count;
    const char *const *decoders;       // informational
    size_t decoder_count;
    uint32_t display_width;            // 0x0: keep the session's size
    uint32_t display_height;
    uint32_t display_refresh_mhz;
    double display_scale;
    bool take_over;                    // §6.4
    int32_t network_profile;           // gdpc_network_profile
    bool drop_until_keyframe_after_loss; // §9.3
} gdpc_session_config;

// One output (§7.2). Colour fields hold session.proto's enum values; 0 is
// "unspecified", i.e. the codec's default (§7.3).
typedef struct {
    uint32_t stream_id;
    uint32_t width;
    uint32_t height;
    uint32_t refresh_mhz;
    double scale;
    int32_t matrix;    // 1 BT.601, 2 BT.709, 3 BT.2020
    int32_t range;     // 1 limited, 2 full
    int32_t primaries; // 1 BT.709, 2 BT.2020
    int32_t transfer;  // 1 sRGB, 2 PQ, 3 HLG
    uint32_t bit_depth;
    int32_t chroma;    // 1 4:2:0, 2 4:2:2, 3 4:4:4
} gdpc_output;

typedef struct {
    const char *codec;
    const gdpc_output *outputs;
    size_t output_count;
    uint32_t bitrate_ceiling_bps;
    bool has_audio;
    const char *audio_codec;
    uint32_t audio_sample_rate_hz;
    uint32_t audio_channels;
    uint32_t audio_frame_ms;
    const char *const *capabilities;   // in effect
    size_t capability_count;
    int32_t network_profile;
    bool via_gateway;
    const char *encoder;
    const char *host_user;
    const char *host_name;
} gdpc_session_accept;

typedef struct {
    void *ctx;
    void (*accepted)(void *ctx, const gdpc_session_accept *accept);
    // Exactly once. `code` is the §12 code (the host's close code, or the
    // one this client closed with), 0 for a plain close.
    void (*closed)(void *ctx, uint64_t code, const char *reason, bool certificate_rejected);
    void (*displays_changed)(void *ctx, const gdpc_output *outputs, size_t count);
    // Return false if the frame can't be used now: it counts as lost (§7.5)
    // and frames are dropped until the next keyframe.
    bool (*video_frame)(void *ctx, const gdpc_video_frame *frame);
    void (*audio_packet)(void *ctx, uint16_t seq, uint32_t pts, const uint8_t *opus, size_t len);
    // `bgra`: width*height*4 bytes, B G R A in memory, premultiplied; 0x0 = no cursor (§7.4).
    void (*cursor_shape)(void *ctx, uint32_t width, uint32_t height, uint32_t hotspot_x, uint32_t hotspot_y,
        const uint8_t *bgra);
    void (*cursor_position)(void *ctx, double x, double y);
    void (*network_profile_changed)(void *ctx, int32_t profile);
    // Answer with gdpc_session_send_diagnostics_report().
    void (*diagnostics_requested)(void *ctx);
} gdpc_session_callbacks;

typedef struct {
    uint32_t rtt_us;            // QUIC smoothed RTT plus any gateway leg (§6.10)
    uint32_t upstream_rtt_us;
    uint16_t path_mtu;
    uint16_t max_datagram_size;
    uint32_t stats_reports_sent;
    uint64_t frames_delivered;
    uint64_t frames_dropped;    // completed but dropped while waiting for a keyframe
    bool has_frames;
    uint32_t highest_frame_id;
    uint64_t loss_bitmap;       // as the next StatsReport would carry it
    uint32_t window_span;       // how many of its 64 bits refer to real frames
    int32_t delay_min_us;       // what the last StatsReport carried
    int32_t delay_avg_us;
    uint32_t delay_samples;
    uint64_t bytes_last_window;
    uint32_t last_window_us;
} gdpc_session_link_stats;

gdpc_session *gdpc_session_create(const gdpc_session_callbacks *callbacks);
void gdpc_session_destroy(gdpc_session *session);
// Starts connecting. Returns false (with `error`) on bad configuration or
// immediate local failure; the outcome arrives through the callbacks.
bool gdpc_session_connect(gdpc_session *session, const gdpc_session_config *config, char *error, size_t error_cap);
int gdpc_session_notify_fd(const gdpc_session *session);
void gdpc_session_dispatch(gdpc_session *session);
// Detach (close with code 0); the desktop session keeps running (§7.10).
void gdpc_session_close(gdpc_session *session);
bool gdpc_session_established(const gdpc_session *session);

// Every 250 ms while established (§7.5).
void gdpc_session_send_stats_report(gdpc_session *session);
void gdpc_session_record_frame_timing(gdpc_session *session, uint32_t decode_us, uint32_t present_us);
// A frame video_frame accepted turned out unusable (the decoder rejected it).
void gdpc_session_mark_frame_discarded(gdpc_session *session, uint8_t stream_id, uint32_t frame_id);
void gdpc_session_request_keyframe(gdpc_session *session, uint32_t stream_id);
void gdpc_session_request_resolution(gdpc_session *session, uint32_t stream_id, uint32_t width, uint32_t height);
void gdpc_session_send_logout(gdpc_session *session);
void gdpc_session_send_diagnostics_report(gdpc_session *session, const uint8_t *text, size_t len);

void gdpc_session_send_key(gdpc_session *session, uint32_t hid_usage, bool pressed);
void gdpc_session_send_pointer_motion(gdpc_session *session, double dx, double dy, bool absolute);
void gdpc_session_send_pointer_button(gdpc_session *session, uint32_t button, bool pressed);
void gdpc_session_send_pointer_axis(gdpc_session *session, double horizontal, double vertical);
// `phase`: 1 down, 2 move, 3 up, 4 cancel (§8.3).
void gdpc_session_send_touch(gdpc_session *session, uint32_t touch_id, int32_t phase, double x, double y);

void gdpc_session_get_link_stats(const gdpc_session *session, gdpc_session_link_stats *out);

// ---------------------------------------------------------------------------
// Test host: a minimal session host on 127.0.0.1 (static token, §6.11), for
// tests and the app's loopback demo. Runs its own thread; every function is
// thread-safe.

typedef struct gdpc_test_host gdpc_test_host;

typedef struct {
    const char *scratch_dir;         // writable, for the certificate files
    const char *token;
    const char *const *codecs;       // what it "encodes"
    size_t codec_count;
    const char *const *capabilities; // what it supports
    size_t capability_count;
    uint32_t width;
    uint32_t height;
    bool audio;                      // advertise SessionAccept.audio (§6.8):
    const char *audio_codec;         //   NULL: "opus"
    uint32_t audio_sample_rate_hz;   //   0: 48000
    uint32_t audio_channels;         //   0: 2
    uint32_t audio_frame_ms;         //   0: 10
    const char *force_codec;         // NULL or a codec to accept regardless
    uint64_t refuse_code;            // 0, or close with this after a good hello
    const char *reject_reason;       // NULL, or send SessionReject
    bool ping_before_accept;
    uint32_t first_frame_id;
    // Keep a pointer like a host: absolute motion places it, relative motion
    // moves it (output pixels, clamped), and a batch of input that moved it
    // relatively is answered with CursorPosition (§7.4).
    bool simulate_pointer;
} gdpc_test_host_config;

// One input event the test host received (§8.2, §8.3).
typedef enum {
    GDPC_TEST_INPUT_KEY = 1,
    GDPC_TEST_INPUT_MOTION = 2,
    GDPC_TEST_INPUT_BUTTON = 3,
    GDPC_TEST_INPUT_AXIS = 4,
    GDPC_TEST_INPUT_TOUCH = 5,
} gdpc_test_input_kind;

typedef struct {
    int32_t kind;      // gdpc_test_input_kind
    uint32_t code;     // HID usage, BTN_* code or touch_id
    bool pressed;      // key, button
    double x, y;       // motion dx/dy, axis horizontal/vertical, touch position
    bool absolute;     // motion
    int32_t phase;     // touch
} gdpc_test_input_event;

typedef struct {
    bool connected;
    bool hello_received;
    char token[128];
    char codecs[128];                // comma-separated, as offered
    char capabilities[128];
    char decoders[128];
    bool take_over;
    bool via_gateway;
    int32_t network_profile;
    uint32_t requested_width;
    uint32_t requested_height;
    bool accepted;
    char accepted_codec[16];
    bool closed;
    uint64_t close_code;

    uint32_t stats_reports;
    uint32_t last_rtt_us;
    bool last_has_stream;
    uint32_t last_highest_frame_id;
    uint64_t last_loss_bitmap;
    uint32_t last_decode_us;
    uint32_t last_present_us;
    uint32_t last_interval_us;
    uint64_t last_bytes_received;
    int32_t last_delay_min_us;
    int32_t last_delay_avg_us;
    uint32_t last_delay_samples;
    uint32_t last_trains;
    uint32_t last_train_datagrams;
    uint32_t last_train_bytes;
    uint64_t bytes_reported;
    uint32_t lost_frame_count;
    uint32_t lost_frame_ids[64];     // the first 64 frames ever reported lost

    uint32_t keyframe_requests;
    uint32_t resolution_requests;
    uint32_t last_resolution_width;
    uint32_t last_resolution_height;
    bool logout_requested;
    uint32_t pongs;
    uint64_t last_pong_nonce;
    size_t diagnostics_report_len;

    uint32_t key_events;
    uint32_t last_key_usage;
    bool last_key_pressed;
    uint32_t pointer_motions;
    double last_motion_x;
    double last_motion_y;
    bool last_motion_absolute;
    uint32_t button_events;
    uint32_t last_button;
    bool last_button_pressed;
    double axis_vertical_sum;
    double axis_horizontal_sum;
    uint32_t touches;
    bool input_before_accept;
    uint32_t input_event_count;      // logged, see gdpc_test_host_input_events
    bool viewer_closed;              // the accepted viewer's connection ended
    uint64_t viewer_close_code;      // its close code (0: a normal close)
    char viewer_close_reason[128];
    double pointer_x, pointer_y;     // with simulate_pointer
    uint32_t cursor_positions_sent;

    uint32_t frames_sent;
    uint32_t next_frame_id;
    uint16_t max_datagram_size;
} gdpc_test_host_observed;

gdpc_test_host *gdpc_test_host_create(const gdpc_test_host_config *config, char *error, size_t error_cap);
void gdpc_test_host_destroy(gdpc_test_host *host);
uint16_t gdpc_test_host_port(const gdpc_test_host *host);
// Writes GDPC_SHA256_HEX_LEN digits and a NUL.
void gdpc_test_host_cert_sha256(const gdpc_test_host *host, char out[GDPC_SHA256_HEX_LEN + 1]);
// Sends one coded frame (copied) as video datagrams with the next frame_id.
// Slices listed in `drop_slices` are not sent. `max_payload` 0: what the path allows.
void gdpc_test_host_send_video_frame(gdpc_test_host *host, const uint8_t *data, size_t len, bool keyframe,
    const uint16_t *drop_slices, size_t drop_count, size_t max_payload);
void gdpc_test_host_send_audio_packet(gdpc_test_host *host, uint16_t seq, uint32_t pts, const uint8_t *opus,
    size_t len);
// seq from 0 at SessionAccept and pts from the session clock, as a host does (§10).
void gdpc_test_host_send_audio(gdpc_test_host *host, const uint8_t *opus, size_t len);
void gdpc_test_host_send_ping(gdpc_test_host *host, uint64_t nonce);
void gdpc_test_host_send_cursor_shape(gdpc_test_host *host, uint32_t width, uint32_t height, uint32_t hotspot_x,
    uint32_t hotspot_y, const uint8_t *argb, size_t len);
void gdpc_test_host_send_cursor_position(gdpc_test_host *host, double x, double y);
void gdpc_test_host_send_displays_changed(gdpc_test_host *host, uint32_t width, uint32_t height);
void gdpc_test_host_send_network_profile(gdpc_test_host *host, int32_t profile);
void gdpc_test_host_send_gateway_path(gdpc_test_host *host, uint32_t upstream_rtt_us);
void gdpc_test_host_send_diagnostics_request(gdpc_test_host *host);
void gdpc_test_host_close(gdpc_test_host *host, uint64_t code);
// Whether a keyframe was asked for (KeyframeRequest or a newly reported
// loss) since the last call.
bool gdpc_test_host_take_keyframe_wanted(gdpc_test_host *host);
void gdpc_test_host_get_observed(const gdpc_test_host *host, gdpc_test_host_observed *out);
// Copies up to `cap` of the input events received so far (the first 8192),
// oldest first, starting at `first`; returns how many were copied.
size_t gdpc_test_host_input_events(const gdpc_test_host *host, size_t first, gdpc_test_input_event *out, size_t cap);

// ---------------------------------------------------------------------------
// Lobby (§4, §5): logging in to a host agent or a broker, ending in a
// Redirect to a session (libgdp's gdp::LobbyClient).
//
// Threading as for gdpc_session: one serial queue, gdpc_lobby_dispatch()
// whenever gdpc_lobby_notify_fd() is readable, every callback from it.

typedef struct gdpc_lobby gdpc_lobby;

typedef struct {
    const char *id;
    const char *name;
} gdpc_session_type;

typedef struct {
    const char *session_id;
    const char *session_type;
    int64_t started_at_unix;
    int64_t last_active_unix;
    bool viewer_attached;  // connecting needs take_over (§6.4)
} gdpc_running_session;

typedef struct {
    const gdpc_session_type *types;
    size_t type_count;
    const char *default_type;
    const gdpc_running_session *running;
    size_t running_count;
} gdpc_session_list;

typedef struct {
    const char *id;
    const char *name;
    bool online;
    bool has_session;
    const char *session_type;
    const gdpc_session_type *types;
    size_t type_count;
    const char *default_type;
} gdpc_device;

typedef struct {
    const char *host;        // never empty: the lobby's own host substituted (§4.7)
    uint16_t port;
    const char *token;
    int64_t expiry_unix;
    const char *cert_sha256; // what the session connection must present (§2.3)
} gdpc_redirect;

typedef struct {
    void *ctx;
    // §2.3: whether to trust the server's certificate, decided right after
    // the handshake and before anything (the username) is sent.
    // `ca_verified`: it chains to the configured CAs and is valid for the
    // name dialed. Returning false ends the login with error().
    bool (*certificate)(void *ctx, const char *cert_sha256, bool ca_verified);
    // Answer each with gdpc_lobby_respond(), in order (§4.5).
    void (*auth_prompt)(void *ctx, const char *prompt, bool echo);
    // A broker's hosts (§5): answer with gdpc_lobby_select_device().
    void (*device_list)(void *ctx, const gdpc_device *devices, size_t count);
    // Answer with gdpc_lobby_open_session().
    void (*session_list)(void *ctx, const gdpc_session_list *list);
    // Success, and the end of the exchange.
    void (*redirect)(void *ctx, const gdpc_redirect *redirect);
    // Failure, and the end: `code` is the LobbyError's or the close's §12
    // code, 0 for a local failure or a refused certificate.
    void (*error)(void *ctx, uint64_t code, const char *message, bool certificate_rejected);
} gdpc_lobby_callbacks;

gdpc_lobby *gdpc_lobby_create(const gdpc_lobby_callbacks *callbacks);
void gdpc_lobby_destroy(gdpc_lobby *lobby);
// `ca_system`: also check the certificate against the platform's CAs;
// `ca_file`: a PEM file of further CAs, or NULL (§2.3).
bool gdpc_lobby_connect(gdpc_lobby *lobby, const char *host, uint16_t port, const char *username, bool ca_system,
    const char *ca_file, char *error, size_t error_cap);
int gdpc_lobby_notify_fd(const gdpc_lobby *lobby);
void gdpc_lobby_dispatch(gdpc_lobby *lobby);
// Whether the connection has ended. After redirect() the server closes it
// with code 0 (§4.2): keep dispatching until then, then destroy.
bool gdpc_lobby_connection_closed(const gdpc_lobby *lobby);
void gdpc_lobby_respond(gdpc_lobby *lobby, const char *answer);
void gdpc_lobby_select_device(gdpc_lobby *lobby, const char *device_id);
// `type_id`: one of the offered ids, or "" for the default (§4.6).
void gdpc_lobby_open_session(gdpc_lobby *lobby, const char *type_id);

// Test lobby: a minimal lobby server on 127.0.0.1 (§4, §5), for tests and
// the demo login. Thread-safe.

typedef struct gdpc_test_lobby gdpc_test_lobby;

typedef struct {
    const char *text;
    bool echo;
    const char *expected;
} gdpc_test_prompt;

typedef struct {
    const char *id;
    const char *name;
    bool online;
    bool has_session;
    const char *session_type;
} gdpc_test_device;

typedef struct {
    const char *scratch_dir;
    const char *username;
    const gdpc_test_prompt *prompts;
    size_t prompt_count;
    const gdpc_session_type *session_types;  // NULL: GNOME and KDE Plasma
    size_t session_type_count;
    const char *default_type;
    bool running_session;
    const char *running_type;
    bool viewer_attached;
    uint64_t refuse_after_auth;
    bool broker;
    const gdpc_test_device *devices;
    size_t device_count;
    const gdpc_test_prompt *device_prompts;
    size_t device_prompt_count;
    const char *redirect_host;   // NULL/empty: the lobby's own host
    uint16_t redirect_port;
    const char *redirect_token;
    const char *redirect_cert_sha256;
} gdpc_test_lobby_config;

typedef struct {
    uint32_t connections;
    bool hello_received;
    uint32_t protocol_version;
    char client_id[128];
    char username[128];
    uint32_t response_count;
    char last_response[128];
    char selected_device[64];
    bool session_open_received;
    char opened_type[64];
    bool redirected;
    uint64_t error_code;
} gdpc_test_lobby_observed;

gdpc_test_lobby *gdpc_test_lobby_create(const gdpc_test_lobby_config *config, char *error, size_t error_cap);
void gdpc_test_lobby_destroy(gdpc_test_lobby *lobby);
uint16_t gdpc_test_lobby_port(const gdpc_test_lobby *lobby);
void gdpc_test_lobby_cert_sha256(const gdpc_test_lobby *lobby, char out[GDPC_SHA256_HEX_LEN + 1]);
void gdpc_test_lobby_get_observed(const gdpc_test_lobby *lobby, gdpc_test_lobby_observed *out);

#ifdef __cplusplus
}
#endif

#endif // GDPCORE_H
