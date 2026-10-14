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

#ifdef __cplusplus
}
#endif

#endif // GDPCORE_H
