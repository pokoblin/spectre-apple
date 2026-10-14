// The C ABI in include/gdpcore.h over libgdp's gdp::LobbyClient and TestLobby.
#include "gdpcore.h"

#include "test_lobby.hpp"

#include "gdp/lobby_client.hpp"

#include <cstdio>
#include <string>
#include <vector>

namespace {

void copy_string(char *dst, size_t cap, const std::string &src) {
	std::snprintf(dst, cap, "%s", src.c_str());
}

std::vector<gdpc_session_type> to_c(const std::vector<gdp::SessionTypeInfo> &types) {
	std::vector<gdpc_session_type> out;
	for (const auto &t : types) out.push_back({t.id.c_str(), t.name.c_str()});
	return out;
}

std::vector<gdpcore::TestLobby::Prompt> prompts(const gdpc_test_prompt *p, size_t n) {
	std::vector<gdpcore::TestLobby::Prompt> out;
	for (size_t i = 0; i < n; i++) {
		out.push_back({p[i].text ? p[i].text : "", p[i].echo, p[i].expected ? p[i].expected : ""});
	}
	return out;
}

// libgdp's LobbyClient, plus whether its connection has ended: after a
// Redirect the server closes it (§4.2), and the caller keeps dispatching
// until it has, rather than drop the connection under the server's close.
class LobbyClient : public gdp::LobbyClient {
public:
	bool connection_closed() const { return !conn_ || conn_->state() == gdp::ConnectionState::kShutdown; }
};

} // namespace

struct gdpc_lobby {
	explicit gdpc_lobby(const gdpc_lobby_callbacks &cb) : callbacks(cb) {
		client.on_certificate = [this](const std::string &sha256) {
			if (!callbacks.certificate) return false;
			return callbacks.certificate(callbacks.ctx, sha256.c_str(), client.certificate_ca_verified());
		};
		client.on_auth_prompt = [this](const std::string &prompt, bool echo) {
			if (callbacks.auth_prompt) callbacks.auth_prompt(callbacks.ctx, prompt.c_str(), echo);
		};
		client.on_session_list = [this](const gdp::SessionListInfo &list) {
			if (!callbacks.session_list) return;
			auto types = to_c(list.types);
			std::vector<gdpc_running_session> running;
			for (const auto &r : list.running) {
				running.push_back({r.session_id.c_str(), r.session_type.c_str(), r.started_at_unix, r.last_active_unix,
					r.viewer_attached});
			}
			gdpc_session_list c{types.data(), types.size(), list.default_type.c_str(), running.data(), running.size()};
			callbacks.session_list(callbacks.ctx, &c);
		};
		client.on_device_list = [this](const std::vector<gdp::DeviceInfo> &devices) {
			if (!callbacks.device_list) return;
			std::vector<std::vector<gdpc_session_type>> types;
			for (const auto &d : devices) types.push_back(to_c(d.types));
			std::vector<gdpc_device> c;
			for (size_t i = 0; i < devices.size(); i++) {
				const auto &d = devices[i];
				c.push_back({d.id.c_str(), d.name.c_str(), d.online, d.has_session, d.session_type.c_str(),
					types[i].data(), types[i].size(), d.default_type.c_str()});
			}
			callbacks.device_list(callbacks.ctx, c.data(), c.size());
		};
		client.on_redirect = [this](const std::string &host, uint16_t port, const std::string &token, int64_t expiry,
								 const std::string &cert) {
			if (!callbacks.redirect) return;
			gdpc_redirect r{host.c_str(), port, token.c_str(), expiry, cert.c_str()};
			callbacks.redirect(callbacks.ctx, &r);
		};
		client.on_error = [this](const std::string &message) {
			if (callbacks.error) {
				callbacks.error(callbacks.ctx, client.error_code(), message.c_str(), client.certificate_rejected());
			}
		};
	}

	gdpc_lobby_callbacks callbacks;
	LobbyClient client;
};

struct gdpc_test_lobby {
	gdpcore::TestLobby lobby;
};

extern "C" {

gdpc_lobby *gdpc_lobby_create(const gdpc_lobby_callbacks *callbacks) {
	return new gdpc_lobby(callbacks ? *callbacks : gdpc_lobby_callbacks{});
}

void gdpc_lobby_destroy(gdpc_lobby *lobby) { delete lobby; }

bool gdpc_lobby_connect(gdpc_lobby *lobby, const char *host, uint16_t port, const char *username, bool ca_system,
	const char *ca_file, char *error, size_t error_cap) {
	auto fail = [&](const char *why) {
		if (error && error_cap) copy_string(error, error_cap, why);
		return false;
	};
	if (!host || !*host || port == 0) return fail("no host or port");
	if (!username || !*username) return fail("no username");
	lobby->client.ca_trust.system = ca_system;
	lobby->client.ca_trust.extra_file = ca_file ? ca_file : "";
	if (!lobby->client.connect(host, port, username)) return fail("could not start the connection");
	return true;
}

int gdpc_lobby_notify_fd(const gdpc_lobby *lobby) { return lobby->client.notify_fd(); }
void gdpc_lobby_dispatch(gdpc_lobby *lobby) { lobby->client.dispatch(); }
bool gdpc_lobby_connection_closed(const gdpc_lobby *lobby) { return lobby->client.connection_closed(); }
void gdpc_lobby_respond(gdpc_lobby *lobby, const char *answer) { lobby->client.respond(answer ? answer : ""); }

void gdpc_lobby_select_device(gdpc_lobby *lobby, const char *device_id) {
	lobby->client.select_device(device_id ? device_id : "");
}

void gdpc_lobby_open_session(gdpc_lobby *lobby, const char *type_id) {
	lobby->client.open_session(type_id ? type_id : "");
}

gdpc_test_lobby *gdpc_test_lobby_create(const gdpc_test_lobby_config *c, char *error, size_t error_cap) {
	gdpcore::TestLobby::Config config;
	if (c->scratch_dir) config.scratch_dir = c->scratch_dir;
	if (c->username) config.username = c->username;
	if (c->prompts) config.prompts = prompts(c->prompts, c->prompt_count);
	if (c->session_types) {
		config.session_types.clear();
		for (size_t i = 0; i < c->session_type_count; i++) {
			config.session_types.emplace_back(c->session_types[i].id, c->session_types[i].name);
		}
	}
	if (c->default_type) config.default_type = c->default_type;
	config.running_session = c->running_session;
	if (c->running_type) config.running_type = c->running_type;
	config.viewer_attached = c->viewer_attached;
	config.refuse_after_auth = c->refuse_after_auth;
	config.broker = c->broker;
	for (size_t i = 0; i < c->device_count; i++) {
		const auto &d = c->devices[i];
		config.devices.push_back({d.id ? d.id : "", d.name ? d.name : "", d.online, d.has_session,
			d.session_type ? d.session_type : ""});
	}
	config.device_prompts = prompts(c->device_prompts, c->device_prompt_count);
	if (c->redirect_host) config.redirect_host = c->redirect_host;
	config.redirect_port = c->redirect_port;
	if (c->redirect_token) config.redirect_token = c->redirect_token;
	if (c->redirect_cert_sha256) config.redirect_cert_sha256 = c->redirect_cert_sha256;

	auto *l = new gdpc_test_lobby;
	std::string err;
	if (!l->lobby.start(config, &err)) {
		if (error && error_cap) copy_string(error, error_cap, err);
		delete l;
		return nullptr;
	}
	return l;
}

void gdpc_test_lobby_destroy(gdpc_test_lobby *lobby) { delete lobby; }
uint16_t gdpc_test_lobby_port(const gdpc_test_lobby *lobby) { return lobby->lobby.port(); }

void gdpc_test_lobby_cert_sha256(const gdpc_test_lobby *lobby, char out[GDPC_SHA256_HEX_LEN + 1]) {
	copy_string(out, GDPC_SHA256_HEX_LEN + 1, lobby->lobby.cert_sha256());
}

void gdpc_test_lobby_get_observed(const gdpc_test_lobby *lobby, gdpc_test_lobby_observed *out) {
	auto o = lobby->lobby.observed();
	*out = gdpc_test_lobby_observed{};
	out->connections = o.connections;
	out->hello_received = o.hello_received;
	out->protocol_version = o.protocol_version;
	copy_string(out->client_id, sizeof(out->client_id), o.client_id);
	copy_string(out->username, sizeof(out->username), o.username);
	out->response_count = static_cast<uint32_t>(o.responses.size());
	if (!o.responses.empty()) copy_string(out->last_response, sizeof(out->last_response), o.responses.back());
	copy_string(out->selected_device, sizeof(out->selected_device), o.selected_device);
	out->session_open_received = o.session_open_received;
	copy_string(out->opened_type, sizeof(out->opened_type), o.opened_type);
	out->redirected = o.redirected;
	out->error_code = o.error_code;
}

} // extern "C"
