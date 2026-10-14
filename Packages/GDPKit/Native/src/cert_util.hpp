// A throwaway self-signed certificate for in-process hosts (the QUIC
// self-test, TestHost): libgdp's Transport::listen() takes PEM file paths.
#pragma once

#include <string>

namespace gdpcore {

struct SelfSignedCert {
	std::string cert_path;
	std::string key_path;
	std::string sha256; // gdp::sha256_hex() of the DER, what a client pins

	SelfSignedCert() = default;
	SelfSignedCert(const SelfSignedCert &) = delete;
	SelfSignedCert &operator=(const SelfSignedCert &) = delete;
	~SelfSignedCert(); // removes the files

	// An ephemeral P-256 key and a one-hour certificate for it, as PEM
	// files under `dir`. Returns an error message, or empty on success.
	std::string generate(const std::string &dir);
};

} // namespace gdpcore
