#include "cert_util.hpp"

#include "gdp/cert_fingerprint.hpp"

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/rand.h>
#include <openssl/x509.h>

#include <unistd.h>

#include <cstdio>
#include <memory>

namespace gdpcore {

SelfSignedCert::~SelfSignedCert() {
	if (!cert_path.empty()) unlink(cert_path.c_str());
	if (!key_path.empty()) unlink(key_path.c_str());
}

std::string SelfSignedCert::generate(const std::string &dir) {
	std::unique_ptr<EVP_PKEY, decltype(&EVP_PKEY_free)> key(EVP_EC_gen("P-256"), EVP_PKEY_free);
	if (!key) return "EVP_EC_gen failed";
	std::unique_ptr<X509, decltype(&X509_free)> x509(X509_new(), X509_free);
	if (!x509) return "X509_new failed";

	uint64_t serial = 0;
	RAND_bytes(reinterpret_cast<unsigned char *>(&serial), sizeof(serial));
	X509_set_version(x509.get(), 2);
	ASN1_INTEGER_set_uint64(X509_get_serialNumber(x509.get()), serial >> 1);
	X509_gmtime_adj(X509_getm_notBefore(x509.get()), -60);
	X509_gmtime_adj(X509_getm_notAfter(x509.get()), 3600);
	X509_set_pubkey(x509.get(), key.get());
	X509_NAME *name = X509_get_subject_name(x509.get());
	X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<const unsigned char *>("localhost"),
		-1, -1, 0);
	X509_set_issuer_name(x509.get(), name);
	if (X509_sign(x509.get(), key.get(), EVP_sha256()) == 0) return "X509_sign failed";

	unsigned char *der = nullptr;
	int der_len = i2d_X509(x509.get(), &der);
	if (der_len <= 0) return "i2d_X509 failed";
	sha256 = gdp::sha256_hex(der, static_cast<size_t>(der_len));
	OPENSSL_free(der);

	std::string base = dir + "/gdpc-selftest-" + std::to_string(getpid()) + "-" + std::to_string(serial & 0xffff);
	cert_path = base + "-cert.pem";
	key_path = base + "-key.pem";
	FILE *f = fopen(cert_path.c_str(), "w");
	if (!f) return "cannot write " + cert_path;
	bool ok = PEM_write_X509(f, x509.get()) == 1;
	fclose(f);
	if (!ok) return "PEM_write_X509 failed";
	f = fopen(key_path.c_str(), "w");
	if (!f) return "cannot write " + key_path;
	ok = PEM_write_PrivateKey(f, key.get(), nullptr, nullptr, 0, nullptr, nullptr) == 1;
	fclose(f);
	if (!ok) return "PEM_write_PrivateKey failed";
	return {};
}

} // namespace gdpcore
