#include "local_serve.hpp"

#include "session.pb.h"

#include <cerrno>

#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gdpcore {

namespace {

int64_t unix_ms(const struct timespec &t) {
	return int64_t(t.tv_sec) * 1000 + t.tv_nsec / 1000000;
}

} // namespace

OpenedFile open_regular(const std::string &path, bool follow) {
	OpenedFile out;
	int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | (follow ? 0 : O_NOFOLLOW));
	if (fd < 0) {
		bool gone = errno == ENOENT || errno == ENOTDIR || errno == ELOOP;
		out.error = gone ? gdp::session::FILE_ERROR_GONE : gdp::session::FILE_ERROR_READ_FAILED;
		return out;
	}
	struct stat st;
	if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
		::close(fd);
		out.error = gdp::session::FILE_ERROR_GONE;
		return out;
	}
	out.fd = fd;
	out.size = uint64_t(st.st_size);
	out.modified_unix_ms = unix_ms(st.st_mtimespec);
	return out;
}

bool is_plain_folder(const std::string &path) {
	struct stat st;
	return ::lstat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

std::string nfc(const std::string &name) {
	// ASCII is NFC already.
	bool ascii = true;
	for (unsigned char c : name) ascii = ascii && c < 0x80;
	if (ascii) return name;
	CFStringRef in = CFStringCreateWithBytes(nullptr, reinterpret_cast<const UInt8 *>(name.data()),
		CFIndex(name.size()), kCFStringEncodingUTF8, false);
	if (!in) return name;
	CFMutableStringRef s = CFStringCreateMutableCopy(nullptr, 0, in);
	CFRelease(in);
	CFStringNormalize(s, kCFStringNormalizationFormC);
	CFIndex len = CFStringGetLength(s), used = 0;
	CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, nullptr, 0, &used);
	std::string out(size_t(used), '\0');
	CFStringGetBytes(s, CFRangeMake(0, len), kCFStringEncodingUTF8, 0, false, reinterpret_cast<UInt8 *>(out.data()),
		used, &used);
	CFRelease(s);
	return out;
}

void nfc_names(gdp::session::FileList *list) {
	for (auto &f : *list->mutable_files()) f.set_name(nfc(f.name()));
}

void nfc_names(gdp::session::FileListing *listing) {
	for (auto &f : *listing->mutable_files()) f.set_name(nfc(f.name()));
}

} // namespace gdpcore
