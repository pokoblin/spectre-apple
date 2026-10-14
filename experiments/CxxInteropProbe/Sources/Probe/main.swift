import CxxStdlib
import LibGDPHeaders

// 1. Free functions with std::string / std::array: work.
let abc: [UInt8] = Array("abc".utf8)
let hex = String(gdp.sha256_hex(abc, abc.count))
print("sha256_hex:", hex, "is_sha256_hex:", gdp.is_sha256_hex(std.string(hex)))
print("format_fingerprint:", String(gdp.format_fingerprint(std.string(hex))))

// 2. POD struct + static decode with pointer out-params: works.
var hdr = gdp.VideoDatagramHeader()
var payload: UnsafePointer<UInt8>? = nil
var payloadLen = 0
var dgram: [UInt8] = [1] + [UInt8](repeating: 0, count: 16) + [0xaa]
dgram[9] = 1 // slice_count
print("decode:", gdp.VideoDatagramHeader.decode(dgram, dgram.count, &hdr, &payload, &payloadLen), payloadLen)

// 3. A std::function parameter can't take a Swift closure, capturing or not:
// _ = gdp.slice_video_frame(hdr, frame, frame.count, 1100, { _, _ in true })
//   error: closure passed to parameter of type 'std.function<...>' that does not accept a closure

// 4. FrameReader imports, but drain() wants a google::protobuf::MessageLite* (see 7).
var reader = gdp.FrameReader()
reader.feed([4, 0, 0, 0], 4)
print("max frame:", reader.max_frame_size())

// 5. Transport: non-copyable, non-movable. Not imported at all unless
//    LibGDPHeaders.apinotes marks it a reference type -- and only "immortal"
//    fits (libgdp has no retain/release), so it is never destroyed. The API
//    notes are only found next to a hand-written module.modulemap.
let transport = gdp.Transport()
print("notify fd:", transport.notify_fd())

// 6. LobbyClient: same API-notes treatment; its callbacks are std::function
//    members, which a Swift closure can't be assigned to:
// lobby.on_error = { (_: std.string) in print("error") }
//   error: cannot assign value of type '(std.string) -> ()' to type 'std.function<...>'
let lobby = gdp.LobbyClient()
print("lobby certificate_rejected:", lobby.certificate_rejected())

// 7. A protobuf-generated message crashes swift-frontend 6.4 (name lookup
//    on gdp.session.ControlEnvelope in session.pb.h):
// var env = gdp.session.ControlEnvelope()
