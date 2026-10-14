#include "test_lobby.hpp"

#include "server_loop.hpp"

#include "gdp/clock.hpp"
#include "gdp/error_codes.hpp"
#include "gdp/framing.hpp"
#include "gdp/version.hpp"
#include "lobby.pb.h"

#include <algorithm>
#include <ctime>
#include <list>
#include <mutex>

namespace gdpcore {

namespace {

constexpr size_t kPreAuthFrameSize = 16 * 1024; // §4.4
constexpr int64_t kTokenLifetimeS = 30;         // §4.8, the reference host's

uint64_t code(gdp::ErrorCode c) {
	return static_cast<uint64_t>(c);
}

} // namespace

struct TestLobby::Impl {
	enum class Stage { kHello, kAuth, kDevice, kSessionOpen, kDone };

	struct Peer {
		std::unique_ptr<gdp::Connection> conn;
		gdp::Stream *stream = nullptr;
		gdp::FrameReader reader;
		Stage stage = Stage::kHello;
		const std::vector<Prompt> *prompts = nullptr;
		size_t prompt = 0;
		bool answers_ok = true;
		bool username_ok = true;
		bool device_chosen = false;
		uint64_t close_at_us = 0;
		uint64_t close_code = 0;
	};

	Config cfg;
	ServerLoop loop; // declared before `peers`: see TestHost
	std::list<std::unique_ptr<Peer>> peers;

	mutable std::mutex mu;
	Observed obs;

	~Impl() { loop.stop(); }

	void tick() {
		uint64_t now = gdp::monotonic_us();
		for (auto &p : peers) {
			if (p->close_at_us && now >= p->close_at_us) {
				p->close_at_us = 0;
				p->conn->close(p->close_code);
			}
		}
	}

	// §4.2: a LobbyError, then a close with the same code -- after a moment,
	// so the message isn't lost to the close.
	void send_error(Peer &p, uint64_t c, const std::string &message) {
		gdp::lobby::LobbyEnvelope env;
		env.mutable_error()->set_code(static_cast<gdp::lobby::LobbyErrorCode>(c));
		env.mutable_error()->set_message(message);
		send(p, env);
		finish(p, c);
		std::lock_guard lock(mu);
		obs.error_code = c;
	}

	void finish(Peer &p, uint64_t c) {
		p.stage = Stage::kDone;
		p.close_code = c;
		p.close_at_us = gdp::monotonic_us() + 200'000;
	}

	void send(Peer &p, const gdp::lobby::LobbyEnvelope &env) {
		if (p.stream) p.stream->send_message(env);
	}

	void on_new_connection(std::unique_ptr<gdp::Connection> conn) {
		auto peer = std::make_unique<Peer>();
		Peer *p = peer.get();
		p->conn = std::move(conn);
		p->reader.set_max_frame_size(kPreAuthFrameSize);
		// The lobby is the first bidi stream the client opens (§2.2), stream 0.
		p->conn->on_control_stream = [this, p](gdp::Stream *s) {
			p->stream = s;
			s->on_data = [this, p](const uint8_t *data, size_t len) { on_data(*p, data, len); };
		};
		peers.push_back(std::move(peer));
		std::lock_guard lock(mu);
		obs.connections++;
	}

	void on_data(Peer &p, const uint8_t *data, size_t len) {
		gdp::lobby::LobbyEnvelope env;
		bool ok = p.reader.feed_and_drain(data, len, &env, [&] {
			if (p.stage == Stage::kDone) return false;
			handle(p, env);
			return p.stage != Stage::kDone;
		});
		if (!ok && p.stage != Stage::kDone) {
			bool too_large = p.reader.last_result() == gdp::FrameReader::Result::kTooLarge;
			p.stage = Stage::kDone;
			p.conn->close(too_large ? code(gdp::ErrorCode::kFrameTooLarge) : code(gdp::ErrorCode::kMalformedFrame));
		}
	}

	void protocol_violation(Peer &p) {
		p.stage = Stage::kDone;
		p.conn->close(code(gdp::ErrorCode::kMalformedFrame)); // §4.2
	}

	void handle(Peer &p, const gdp::lobby::LobbyEnvelope &env) {
		switch (p.stage) {
		case Stage::kHello: {
			if (!env.has_hello()) return protocol_violation(p);
			const auto &h = env.hello();
			{
				std::lock_guard lock(mu);
				obs.hello_received = true;
				obs.protocol_version = h.protocol_version();
				obs.client_id = h.client_id();
				obs.username = h.username();
			}
			if (h.protocol_version() != gdp::kWireVersion) {
				return send_error(p, code(gdp::ErrorCode::kVersionMismatch), "unsupported protocol version");
			}
			p.username_ok = h.username() == cfg.username;
			p.prompts = &cfg.prompts;
			p.prompt = 0;
			next_prompt_or_done(p);
			break;
		}
		case Stage::kAuth: {
			if (!env.has_auth_response()) return protocol_violation(p);
			{
				std::lock_guard lock(mu);
				obs.responses.push_back(env.auth_response().response());
			}
			if (env.auth_response().response() != (*p.prompts)[p.prompt].expected) p.answers_ok = false;
			p.prompt++;
			next_prompt_or_done(p);
			break;
		}
		case Stage::kDevice: {
			if (!env.has_device_select()) return protocol_violation(p);
			const std::string &id = env.device_select().device_id();
			{
				std::lock_guard lock(mu);
				obs.selected_device = id;
			}
			auto it = std::find_if(cfg.devices.begin(), cfg.devices.end(), [&](const Device &d) { return d.id == id; });
			if (it == cfg.devices.end()) {
				return send_error(p, code(gdp::ErrorCode::kNotEntitled), "that device is not one of yours");
			}
			if (!it->online) return send_error(p, code(gdp::ErrorCode::kHostOffline), it->name + " is offline");
			p.device_chosen = true;
			// §5.3: the host's own prompts beyond the password, relayed.
			p.prompts = &cfg.device_prompts;
			p.prompt = 0;
			next_prompt_or_done(p);
			break;
		}
		case Stage::kSessionOpen: {
			if (!env.has_session_open()) return protocol_violation(p);
			std::string type = env.session_open().session_type();
			{
				std::lock_guard lock(mu);
				obs.session_open_received = true;
				obs.opened_type = type;
			}
			if (type.empty()) type = cfg.default_type;
			bool known = std::any_of(cfg.session_types.begin(), cfg.session_types.end(),
				[&](const auto &t) { return t.first == type; });
			// §4.6: an unknown id is refused -- unless a session is already
			// running, which any SessionOpen reattaches to.
			if (!known && !cfg.running_session) {
				return send_error(p, code(gdp::ErrorCode::kUnknownSessionType), "unknown session type '" + type + "'");
			}
			gdp::lobby::LobbyEnvelope out;
			auto *r = out.mutable_redirect();
			r->set_host(cfg.redirect_host);
			r->set_port(cfg.redirect_port);
			r->set_token(cfg.redirect_token);
			r->set_expiry_unix(static_cast<int64_t>(std::time(nullptr)) + kTokenLifetimeS);
			r->set_cert_sha256(cfg.redirect_cert_sha256);
			send(p, out);
			finish(p, 0);
			std::lock_guard lock(mu);
			obs.redirected = true;
			break;
		}
		case Stage::kDone:
			break;
		}
	}

	void next_prompt_or_done(Peer &p) {
		if (p.prompt < p.prompts->size()) {
			const Prompt &q = (*p.prompts)[p.prompt];
			gdp::lobby::LobbyEnvelope env;
			env.mutable_auth_challenge()->set_prompt(q.text);
			env.mutable_auth_challenge()->set_echo_input(q.echo);
			send(p, env);
			p.stage = Stage::kAuth;
			return;
		}
		// §4.5: every failure is AUTH_FAILED, nothing more specific -- a
		// wrong username looks exactly like a wrong password.
		if (!p.answers_ok || !p.username_ok) {
			return send_error(p, code(gdp::ErrorCode::kAuthFailed), "authentication failed");
		}
		p.reader.set_max_frame_size(gdp::kMaxFrameSize);
		if (cfg.broker && !p.device_chosen) {
			gdp::lobby::LobbyEnvelope env;
			auto *list = env.mutable_device_list();
			for (const auto &d : cfg.devices) {
				auto *dev = list->add_devices();
				dev->set_id(d.id);
				dev->set_name(d.name);
				dev->set_online(d.online);
				dev->set_has_session(d.has_session);
				dev->set_session_type(d.session_type);
				if (d.online) {
					for (const auto &t : cfg.session_types) {
						auto *st = dev->add_available_types();
						st->set_id(t.first);
						st->set_name(t.second);
					}
					dev->set_default_type(cfg.default_type);
				}
			}
			send(p, env);
			p.stage = Stage::kDevice;
			return;
		}
		if (cfg.refuse_after_auth) {
			return send_error(p, cfg.refuse_after_auth, gdp::describe_error_code(cfg.refuse_after_auth));
		}
		gdp::lobby::LobbyEnvelope env;
		auto *list = env.mutable_session_list();
		for (const auto &t : cfg.session_types) {
			auto *st = list->add_available_types();
			st->set_id(t.first);
			st->set_name(t.second);
		}
		list->set_default_type(cfg.default_type);
		if (cfg.running_session) {
			auto *s = list->add_sessions();
			s->set_session_id("s-1");
			s->set_session_type(cfg.running_type);
			s->set_started_at_unix(static_cast<int64_t>(std::time(nullptr)) - 3600);
			s->set_last_active_unix(static_cast<int64_t>(std::time(nullptr)) - 60);
			s->set_viewer_attached(cfg.viewer_attached);
		}
		send(p, env);
		p.stage = Stage::kSessionOpen;
	}
};

TestLobby::TestLobby() : impl_(std::make_unique<Impl>()) {}
TestLobby::~TestLobby() = default;

bool TestLobby::start(const Config &config, std::string *error) {
	Impl &m = *impl_;
	m.cfg = config;
	if (!m.loop.start(
			config.scratch_dir, [&m](std::unique_ptr<gdp::Connection> conn) { m.on_new_connection(std::move(conn)); },
			[&m] { m.tick(); }, error)) {
		return false;
	}
	port_ = m.loop.port();
	cert_sha256_ = m.loop.cert_sha256();
	return true;
}

TestLobby::Observed TestLobby::observed() const {
	std::lock_guard lock(impl_->mu);
	return impl_->obs;
}

} // namespace gdpcore
