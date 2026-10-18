#include "local_serve.hpp"

#include "session.pb.h"

#include <algorithm>
#include <cerrno>

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace gdpcore {

namespace {

int64_t unix_ms(const struct timespec &t) {
	return int64_t(t.tv_sec) * 1000 + t.tv_nsec / 1000000;
}

// Opened without waiting: a FIFO (or a device) would otherwise hold the
// worker until something writes to it. Once it is known to be a regular
// file, reads block as usual.
void blocking(int fd) {
	::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL) & ~O_NONBLOCK);
}

} // namespace

OpenedFile open_regular(const std::string &path, bool follow) {
	OpenedFile out;
	int fd = ::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NONBLOCK | (follow ? 0 : O_NOFOLLOW));
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
	blocking(fd);
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

namespace {

bool hidden(const std::string &name, const struct stat &st, bool include_hidden) {
	return !include_hidden && (name[0] == '.' || (st.st_flags & UF_HIDDEN));
}

} // namespace

OpenedFile open_beneath(int root, const std::string &path, bool folder, bool include_hidden) {
	OpenedFile out;
	out.error = gdp::session::FILE_ERROR_GONE;
	std::vector<std::string> parts;
	if (!path.empty()) {
		size_t start = 0;
		for (;;) {
			size_t slash = path.find('/', start);
			parts.push_back(path.substr(start, slash == std::string::npos ? std::string::npos : slash - start));
			if (slash == std::string::npos) break;
			start = slash + 1;
		}
	}
	for (const std::string &part : parts) {
		// Empty (a leading, trailing or doubled '/'), ".", "..", '/', '\\',
		// control characters, over 255 bytes.
		if (!gdp::valid_file_name(part)) return out;
	}
	int fd = ::openat(root, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd < 0) return out;
	for (size_t i = 0; i < parts.size(); i++) {
		bool last = i + 1 == parts.size();
		int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (!last || folder ? O_DIRECTORY : 0);
		int next = ::openat(fd, parts[i].c_str(), flags);
		::close(fd);
		if (next < 0) {
			if (errno != ENOENT && errno != ENOTDIR && errno != ELOOP) out.error = gdp::session::FILE_ERROR_READ_FAILED;
			return out;
		}
		fd = next;
		struct stat st;
		if (::fstat(fd, &st) != 0 || hidden(parts[i], st, include_hidden)) {
			::close(fd);
			return out;
		}
	}
	struct stat st;
	if (::fstat(fd, &st) != 0 || (folder ? !S_ISDIR(st.st_mode) : !S_ISREG(st.st_mode))) {
		::close(fd);
		return out;
	}
	blocking(fd);
	out.fd = fd;
	out.error = 0;
	out.size = folder ? 0 : uint64_t(st.st_size);
	out.modified_unix_ms = unix_ms(st.st_mtimespec);
	return out;
}

std::vector<gdp::session::FileListing> list_shared_folder(int fd, bool include_hidden, size_t frame_budget) {
	std::vector<gdp::session::FileListEntry> entries;
	int dup_fd = ::dup(fd);
	DIR *dir = dup_fd >= 0 ? ::fdopendir(dup_fd) : nullptr;
	if (!dir && dup_fd >= 0) ::close(dup_fd);
	if (dir) {
		::rewinddir(dir);
		while (struct dirent *e = ::readdir(dir)) {
			std::string name = e->d_name;
			if (name == "." || name == ".." || !gdp::valid_file_name(name)) continue;
			struct stat st;
			if (::fstatat(fd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0) continue;
			if (!(S_ISDIR(st.st_mode) || S_ISREG(st.st_mode)) || hidden(name, st, include_hidden)) continue;
			gdp::session::FileListEntry entry;
			entry.set_name(nfc(name));
			entry.set_directory(S_ISDIR(st.st_mode));
			entry.set_size(S_ISREG(st.st_mode) ? uint64_t(st.st_size) : 0);
			entry.set_modified_unix_ms(unix_ms(st.st_mtimespec));
			// The host asks for a folder's contents when it is opened.
			entry.set_unlisted(S_ISDIR(st.st_mode));
			entries.push_back(std::move(entry));
		}
		::closedir(dir);
	}
	std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) { return a.name() < b.name(); });
	// Two names the same once composed: the first only.
	entries.erase(std::unique(entries.begin(), entries.end(),
					  [](const auto &a, const auto &b) { return a.name() == b.name(); }),
		entries.end());
	std::vector<gdp::session::FileListing> frames(1);
	for (auto &entry : entries) {
		if (frames.back().files_size() > 0 &&
			frames.back().ByteSizeLong() + entry.ByteSizeLong() + 16 > frame_budget) {
			frames.emplace_back();
		}
		*frames.back().add_files() = std::move(entry);
	}
	return frames;
}

} // namespace gdpcore
