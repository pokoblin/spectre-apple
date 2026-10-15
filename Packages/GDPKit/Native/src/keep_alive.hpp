// How often the client's connections send a QUIC PING when they have been
// quiet (gdp::Connection::set_keep_alive). libgdp's idle timeout is 30 s on
// both ends, and a connection may sit idle far longer: a lobby prompt the
// user leaves open, a session whose desktop is still (gdp-spec.md §2.1).
// 10 s is §13.1's interval for the host channel. See docs/keep-alive.md.
#pragma once

#include <cstdint>

namespace gdpcore {

constexpr uint32_t kKeepAliveMs = 10'000;

} // namespace gdpcore
