// A minimal lobby server (gdp-spec.md §4, and §5's broker additions),
// written from the spec, for tests: one account with a scripted list of
// prompts, a list of desktop types, optionally a device list, and a
// Redirect to a session host of the caller's choosing.
// Runs its own thread; every public method is thread-safe.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace gdpcore {

class TestLobby {
public:
	struct Prompt {
		std::string text;
		bool echo = false;
		std::string expected;
	};

	struct Device {
		std::string id;
		std::string name;
		bool online = true;
		bool has_session = false;
		std::string session_type;
	};

	struct Config {
		std::string scratch_dir;
		std::string username = "demo";
		// One AuthChallenge per entry, in order (§4.5); any wrong answer is AUTH_FAILED.
		std::vector<Prompt> prompts = {{"Password: ", false, "demo"}};
		std::vector<std::pair<std::string, std::string>> session_types = {{"gnome", "GNOME"}, {"plasma", "KDE Plasma"}};
		std::string default_type = "gnome";
		bool running_session = false; // the user already has a session (§4.6)
		std::string running_type = "gnome";
		bool viewer_attached = false;
		uint64_t refuse_after_auth = 0; // e.g. 23 LOCAL_SESSION_ACTIVE, 31 HOST_FULL (§4.5)
		// Broker (§5): a DeviceList after authentication, then the chosen
		// host's own prompts beyond the password.
		bool broker = false;
		std::vector<Device> devices;
		std::vector<Prompt> device_prompts;
		// The Redirect (§4.7): an empty host means "the host the lobby was dialed by".
		std::string redirect_host;
		uint16_t redirect_port = 0;
		std::string redirect_token;
		std::string redirect_cert_sha256;
	};

	struct Observed {
		uint32_t connections = 0;
		bool hello_received = false;
		uint32_t protocol_version = 0;
		std::string client_id;
		std::string username;
		std::vector<std::string> responses;
		std::string selected_device;
		bool session_open_received = false;
		std::string opened_type; // as the client sent it (empty = the default)
		bool redirected = false;
		uint64_t error_code = 0; // the LobbyError this server sent, if any
	};

	TestLobby();
	~TestLobby();
	TestLobby(const TestLobby &) = delete;
	TestLobby &operator=(const TestLobby &) = delete;

	bool start(const Config &config, std::string *error);
	uint16_t port() const { return port_; }
	const std::string &cert_sha256() const { return cert_sha256_; }
	Observed observed() const;

private:
	struct Impl;
	std::unique_ptr<Impl> impl_;
	uint16_t port_ = 0;
	std::string cert_sha256_;
};

} // namespace gdpcore
