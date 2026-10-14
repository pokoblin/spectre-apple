# spectre-apple

**English** | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [Español](README.es.md)

A native Apple client for the [ghost](https://github.com/jsaiko/ghost) remote desktop, for macOS, iPadOS and iOS (Apple silicon / arm64 only). The app is called **Spectre**; its bundle ID is `org.ghost.spectre.apple`.

> **Acknowledgements**: this project is inspired by [ghost](https://github.com/jsaiko/ghost) by [Joseph Saiko](https://saiko.dev), a complete remote desktop system made up of the GDP protocol, the wraith host and the spectre client for Linux. spectre-apple brings Apple devices to ghost: it uses ghost's protocol library, libgdp, is written from ghost's published protocol specification and design documents, and borrows the name Spectre from the upstream client. Many thanks to the author for open-sourcing ghost and for releasing libgdp and the protocol specification under the MIT license; this project would not exist without them. spectre-apple is an independent, third-party client and is not part of the ghost project.

![A session on iPad in trackpad mode, with the remote cursor drawn by Metal](docs/images/ipad-trackpad-mode.jpg)

- **Protocol**: upstream's C++ libgdp (QUIC with ngtcp2 and OpenSSL, protobuf, zstd), built as static libraries into an xcframework and exposed to Swift through a thin C ABI.
- **Platform**: Swift 6, SwiftUI, Metal and VideoToolbox. The client side of sessions, login and input is written from the GDP specification (`third_party/ghost/docs/spec/gdp-spec.md`).

The design notes and measurements under [`docs/`](docs/) are written in Simplified Chinese.

## Status

Working:

- **Login**: lobby login (§4, §5); the server's certificate is confirmed on first connection and remembered (trust on first use); interactive authentication following the server's prompts; choosing a device and a desktop session; taking over a running session. See [docs/login.md](docs/login.md).
- **Video**: H.264 and HEVC, decoded in hardware by VideoToolbox and handed to Metal without copies; frame loss and latency statistics reported back to the host (StatsReport). See [docs/session-client.md](docs/session-client.md) and [docs/prototype-findings.md](docs/prototype-findings.md).
- **Input**: keys sent by physical position; the mouse with absolute positions, all buttons and smooth scrolling, plus a captured mode that sends relative motion; the remote cursor drawn locally; on iPad, hardware keyboards, trackpads and mice, and fingers in either a "direct touch" or a "trackpad" mode. See [docs/input.md](docs/input.md).
- **Audio**: the remote desktop's sound (Opus, decoded by the system's own codec) through a 60 ms jitter buffer that conceals lost packets; mute from the toolbar. See [docs/audio.md](docs/audio.md).
- **Session control**: disconnect (the remote session keeps running) and log out (ends the remote session).

Not done yet: the microphone, clipboard, gamepads, the lossless refinement layer (refine), an on-screen keyboard, AV1 and PyroWave.

## Building

### Requirements

- Xcode 27 (with the iOS 27 simulator runtime)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `cmake` (3.25+) and `ninja`: `brew install cmake ninja`
- [vcpkg](https://github.com/microsoft/vcpkg), preferably pinned to the commit upstream CI uses:

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

If vcpkg is not in `~/src/vcpkg`, set `VCPKG_ROOT` for the commands below.

### Steps

1. Get the code, including the upstream ghost submodule:

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

   In an existing clone, fetch the submodule with `git submodule update --init`.

2. Build `GDPCore.xcframework`: libgdp and its dependencies (static vcpkg libraries) plus the C bridge, merged into `Packages/GDPKit/Artifacts/GDPCore.xcframework` (not committed). The first build of the dependencies takes a few minutes; later builds use vcpkg's binary cache. Logs go to `build/logs/`.

   ```bash
   scripts/build-gdpcore.sh
   ```

   It builds `macos`, `ios` and `ios-simulator` by default; name some of them to build only those, for example `scripts/build-gdpcore.sh macos`.

3. Generate the Xcode project, open `Spectre.xcodeproj` and run the `Spectre` scheme:

   ```bash
   xcodegen generate
   ```

   Or build the macOS app from the command line:

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

To run on a device, choose a development team for the target in Xcode.

## Using it

The app opens on the login screen: enter the server (`host[:port]`, port 4442 by default) and your user name, answer the server's prompts, then pick a desktop to start the session. On the first connection you are asked to confirm the server's certificate fingerprint.

**No server?** Tap **Try the demo host** (user demo, password demo): the app starts a test lobby and a test host inside itself and goes through the whole login and session flow, showing a test stream, with the statistics overlay listing the input the host received.

**Keyboard and mouse**: keys are sent by physical position, and the remote keyboard layout decides which characters they type. Cmd is sent as Super (the Windows key), so copy and paste on the remote desktop are still Ctrl+C and Ctrl+V. Only these three shortcuts stay local:

| Shortcut | Action |
|---|---|
| Ctrl+Cmd+G | Capture or release the mouse (relative motion for games and 3D views); also the Capture Mouse button in the toolbar |
| Ctrl+Cmd+F | Full screen |
| Cmd+Q | Quit |

**Fingers on iPad and iPhone**: switch between two modes with the toolbar button.

- **Touch**: the pointer goes where you touch. Tap to left-click, long-press to right-click, drag with one finger to left-drag, drag with two fingers to scroll, and tap with two or three fingers to right- or middle-click.
- **Trackpad**: the screen works like a trackpad. Move the cursor with one finger and tap to click.

**Sound**: the remote desktop's sound plays when the host sends it (wraith does when it can capture the session's audio). The toolbar's **Mute** button silences it on this device only; the setting is remembered. The demo and loopback host beep once a second.

## Development

### Tests

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

Both packages have an in-process test host (and test lobby) for end-to-end tests over a real QUIC loopback connection. SpectreKit's tests also check the colours of H.264 and HEVC colour bars and render with Metal. To run them in the iPad simulator:

```bash
(cd Packages/GDPKit && xcodebuild test -scheme GDPKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-GDPKit)
```

```bash
(cd Packages/SpectreKit && xcodebuild test -scheme SpectreKit -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -derivedDataPath ../../build/DerivedData-SpectreKit)
```

### Skipping the login

Started with any of the options below, the app skips the login and plays straight away. It first encodes a 10-second 1080p60 test stream with VideoToolbox (about 3 seconds), then loops it; the top left shows decode, presentation and session statistics, updated every second and also printed to stdout. The toolbar switches the source, H.264/HEVC and the presentation pacing. There are three sources:

- **Loopback** (the default): a test host inside the app sends the test stream over a real GDP session (QUIC on 127.0.0.1).
- **Direct**: the test stream goes straight to the decoder, with no network.
- **Remote**: a wraith started with a static token (§6.11):

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --connect HOST:PORT --token TOKEN --fingerprint SHA256
```

Benchmark mode: measures for N seconds after a 2-second warm-up, prints the statistics and exits.

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

Other options: `--source loopback|direct`, `--codec h264|h265`, `--mode onArrival|displayLink`, `--in-flight <N, 0 for no limit>`, `--screen <screen index>`, `--rate <display link Hz>`, `--min-present-ms <ms>`.

### iOS and iPadOS simulator

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

On iOS the app starts from a UIKit app delegate, so that its root view controller can lock the pointer (see [docs/input.md](docs/input.md)). If an older build (with the SwiftUI entry point) was installed, uninstall it once (`xcrun simctl uninstall booted org.ghost.spectre.apple`); otherwise the system restores the old window and it stays black.

In the simulator VideoToolbox decodes in software and there is no `presentedTime`, so timings measured there can't be compared with a device or macOS.

### Layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen project (one multiplatform macOS + iOS app target) |
| `App/` | Per-platform entry points and the UI (login, session) |
| `Packages/GDPKit/` | The C bridge to libgdp (`Native/`) and its Swift wrapper: sessions, lobby, test host |
| `Packages/SpectreKit/` | Shared code: session, VideoToolbox decoding, Metal presentation, input, login flow |
| `scripts/` | Scripts that build the dependencies and the xcframework |
| `docs/` | Design notes and measurements (in Simplified Chinese) |
| `experiments/` | One-off experiments (such as a Swift/C++ interop probe), not part of the app build |
| `third_party/ghost/` | Upstream ghost (git submodule, read-only) |

### Documents

- [docs/prototype-findings.md](docs/prototype-findings.md): the prototype's three technical risks and how each was settled (calling libgdp from Swift, zero-copy presentation, cross-compiling for iOS)
- [docs/session-client.md](docs/session-client.md): the session layer, checked against §6–§11 of the specification
- [docs/login.md](docs/login.md): lobby login, certificate trust, the demo
- [docs/input.md](docs/input.md): keyboard, mouse, cursor, touch
- [docs/audio.md](docs/audio.md): audio, jitter buffer, Opus decoding

## License

[MIT](LICENSE).

- In upstream ghost, `libgdp/` and the protocol specification are MIT, and everything else (including upstream's own spectre client) is GPL-3.0-only. This project builds only `libgdp/`; its client code is written from the specification and public standards, and no code from the GPL parts is copied or ported.
- The app links ngtcp2, OpenSSL, Protocol Buffers, Abseil and zstd statically, all under permissive licenses (MIT, Apache-2.0, BSD-3-Clause). A binary distribution must include their notices: see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
