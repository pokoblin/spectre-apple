// The scaffolding the in-process test servers (TestHost, TestLobby) share:
// a throwaway certificate, a libgdp Transport listening on a free port, and
// a thread that pumps it and runs commands posted from other threads.
#pragma once

#include "cert_util.hpp"

#include "gdp/transport.hpp"

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace gdpcore {

class ServerLoop {
public:
	ServerLoop() = default;
	~ServerLoop() { stop(); }
	ServerLoop(const ServerLoop &) = delete;
	ServerLoop &operator=(const ServerLoop &) = delete;

	// Generates the certificate under `scratch_dir`, listens with ALPN
	// gdp/1 on a random free port and starts the thread. `on_tick` runs on
	// the thread every few milliseconds. Returns false with `error` set.
	bool start(const std::string &scratch_dir, gdp::Transport::NewConnectionHandler on_new_connection,
		std::function<void()> on_tick, std::string *error);
	// Stops and joins the thread. Owners call it before destroying the
	// connections the thread's callbacks use.
	void stop();

	// Runs `fn` on the loop's thread.
	void post(std::function<void()> fn);

	uint16_t port() const { return port_; }
	const std::string &cert_sha256() const { return cert_.sha256; }

private:
	void run();

	SelfSignedCert cert_;
	gdp::Transport transport_;
	uint16_t port_ = 0;
	std::function<void()> on_tick_;
	std::thread thread_;
	std::atomic<bool> stop_{false};
	std::mutex mu_;
	std::vector<std::function<void()>> commands_;
};

} // namespace gdpcore
