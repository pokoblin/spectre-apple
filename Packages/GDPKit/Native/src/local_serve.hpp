// The client's own files, as the host reads them (gdp-spec.md §7.12,
// `file-clipboard` and `file-share`): opening what a request names without
// leaving what the user picked, and names as the wire carries them. Plain
// POSIX, run off the session's thread (gdp::Worker): a file may sit on a
// slow or network drive.
#pragma once

#include "gdp/file_list.hpp"

#include <cstdint>
#include <string>
#include <vector>

namespace gdpcore {

// A regular file, opened read-only for the host, or why not (a
// FileErrorCode: GONE when it isn't there or isn't a regular file,
// READ_FAILED when it can't be opened).
struct OpenedFile {
	int fd = -1;
	uint64_t size = 0;
	int64_t modified_unix_ms = 0;
	int32_t error = 0;
};

// `path` itself. `follow`: it may be a symbolic link (something the user
// copied, §7.12); otherwise one is refused.
OpenedFile open_regular(const std::string &path, bool follow);

// Whether `path` is a folder (not a symbolic link to one).
bool is_plain_folder(const std::string &path);

// `name` in Unicode Normalization Form C, which §7.12 has the sender use:
// Apple's file systems keep a name as it was written, often decomposed.
std::string nfc(const std::string &name);
// Every name in the list or listing, NFC.
void nfc_names(gdp::session::FileList *list);
void nfc_names(gdp::session::FileListing *listing);

} // namespace gdpcore
