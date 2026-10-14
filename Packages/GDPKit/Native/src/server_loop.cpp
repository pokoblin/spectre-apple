#include "server_loop.hpp"

#include "gdp/version.hpp"

#include <openssl/rand.h>
#include <poll.h>

namespace gdpcore {

bool ServerLoop::start(const std::string &scratch_dir, gdp::Transport::NewConnectionHandler on_new_connection,
	std::function<void()> on_tick, std::string *error) {
	if (std::string err = cert_.generate(scratch_dir.empty() ? "/tmp" : scratch_dir); !err.empty()) {
		if (error) *error = "certificate: " + err;
		return false;
	}
	// Transport::listen() can't report an ephemeral port: try random high ones.
	for (int attempt = 0; attempt < 16 && port_ == 0; attempt++) {
		uint16_t candidate = 0;
		RAND_bytes(reinterpret_cast<unsigned char *>(&candidate), sizeof(candidate));
		candidate = static_cast<uint16_t>(49152 + candidate % 16000);
		bool in_use = false;
		if (transport_.listen(candidate, gdp::kAlpn, cert_.cert_path, cert_.key_path, on_new_connection, &in_use)) {
			port_ = candidate;
		} else if (!in_use) {
			if (error) *error = "Transport::listen failed";
			return false;
		}
	}
	if (port_ == 0) {
		if (error) *error = "no free UDP port";
		return false;
	}
	on_tick_ = std::move(on_tick);
	thread_ = std::thread([this] { run(); });
	return true;
}

void ServerLoop::stop() {
	stop_.store(true);
	if (thread_.joinable()) thread_.join();
}

void ServerLoop::post(std::function<void()> fn) {
	std::lock_guard lock(mu_);
	commands_.push_back(std::move(fn));
}

void ServerLoop::run() {
	while (!stop_.load()) {
		pollfd fd{transport_.notify_fd(), POLLIN, 0};
		poll(&fd, 1, 5);
		transport_.dispatch();
		std::vector<std::function<void()>> todo;
		{
			std::lock_guard lock(mu_);
			todo.swap(commands_);
		}
		for (auto &fn : todo) fn();
		if (on_tick_) on_tick_();
	}
}

} // namespace gdpcore
