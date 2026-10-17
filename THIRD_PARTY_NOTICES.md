# Third-party notices

spectre-apple's own code is MIT (see [LICENSE](LICENSE)). The app also
contains the libraries below, built from source by
`scripts/build-gdpcore.sh` and linked statically into `GDPCore.xcframework`,
and PyroWave, built by `scripts/build-pyrowave.sh` into
`PyroWave.xcframework`.
None of them is committed to this repository; a binary distribution of the
app (a .app, an .ipa, an App Store build) must carry their notices.

| Library | Version | License | Source |
|---|---|---|---|
| libgdp (from ghost) | submodule `third_party/ghost` | MIT | https://github.com/jsaiko/ghost (`libgdp/`), built from the fork https://github.com/pokoblin/ghost |
| ngtcp2 | 1.25.0 | MIT | https://github.com/ngtcp2/ngtcp2 |
| OpenSSL | 3.6.4 | Apache-2.0 | https://github.com/openssl/openssl |
| Protocol Buffers | 6.33.4 | BSD-3-Clause | https://github.com/protocolbuffers/protobuf |
| utf8_range (part of Protocol Buffers) | 6.33.4 | MIT | https://github.com/protocolbuffers/protobuf |
| Abseil | 20260107.1 | Apache-2.0 | https://github.com/abseil/abseil-cpp |
| Zstandard | 1.5.7 | BSD-3-Clause (dual BSD/GPLv2, used under BSD) | https://github.com/facebook/zstd |
| PyroWave (Metal port) | submodule `third_party/pyrowave`, commit 89f7e47 | MIT | https://github.com/Themaister/pyrowave (`metal/`) |

Versions are those resolved by vcpkg at the baseline pinned in
`scripts/vcpkg/vcpkg.json`; each package's full license text is installed by
vcpkg as `build/vcpkg/<triplet>/<triplet>/share/<package>/copyright`.

## ghost

The `third_party/ghost` submodule is ghost: for now the pokoblin/ghost fork,
which is upstream plus file transfer (gdp-spec.md §7.12). Only its
`libgdp/` directory (and the protocol specification under `docs/spec/`,
which this project implements) are MIT; everything else in ghost, including
its own `spectre` client and its artwork, is GPL-3.0-only. spectre-apple
builds only `libgdp/` and contains no code, tables or artwork copied or
translated from the GPL parts.

## PyroWave

The `third_party/pyrowave` submodule is PyroWave by Hans-Kristian Arntzen,
pinned to the commit ghost builds its host with
(`third_party/ghost/packaging/build-pyrowave.sh`), as gdp-spec.md §6.6
requires. spectre-apple builds only its native
Metal port, `metal/`, which needs neither Granite nor Vulkan; its license is
the repository's `LICENSE` (MIT).
