<div align="center">

<img src="assets/app-icon.png" width="128" alt="The Spectre icon">

# spectre-apple

**Spectre**, a native client for the [ghost](https://github.com/jsaiko/ghost) remote desktop on Mac, iPad and iPhone

[![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iPadOS%20%7C%20iOS%2027-lightgrey)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

**English** | [简体中文](README.zh-Hans.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [Español](README.es.md)

</div>

![Spectre on the Mac, connected to a GNOME desktop on an Ubuntu host](assets/macos-session.webp)

ghost is an open-source remote desktop system: a host (wraith) streams a Linux desktop over the GDP protocol, and a client shows it and sends input back. spectre-apple is that client for Apple devices, written in Swift with SwiftUI, Metal and VideoToolbox on top of ghost's protocol library, libgdp.

It is an independent, third-party client, not part of the ghost project (see [Acknowledgements](#acknowledgements)).

## Features

**Connecting**

- Sign in with a user name and password, answering any further prompts such as a one-time code, then pick a device and a desktop session, or take over a running one.
- Trust on first use: confirm the server's certificate fingerprint once and it is remembered; **Trusted Servers…** lists and forgets them.
- Save the password with the server for one-tap Connect, optionally in the Keychain.
- Lost connections (Wi-Fi changes, sleep, iOS suspending the app) reconnect by themselves.
- Disconnect (the desktop session keeps running) or log out (it ends).

**Picture and sound**

- H.264, HEVC and AV1 decoded in hardware and presented with Metal without copying frames. AV1 is asked for first on devices that decode it in hardware (Apple M3, A17 Pro and later), and used when the host's GPU can encode it; otherwise HEVC.
- Lossless refinement: once part of the screen stops changing, the host sends it again losslessly and it is shown pixel-exact over the video, so text and lines stay crisp. On by default; **More › Lossless Refinement** turns it off to spare the host the work.
- PyroWave on a wired network: when the host is on the same wired network at 1 Gbit/s or more, Spectre asks for PyroWave first, an intra-only wavelet codec that looks close to lossless at a few hundred Mbit/s and decodes on the GPU in about a millisecond. Over Wi-Fi, a slower link or another network, the usual codecs are used. It needs a host with PyroWave turned on and a GPU quick enough to encode it: a small integrated GPU may not keep up at high resolutions (an Intel N100 manages about 25 fps at 2560×1496). **More › PyroWave on Wired Networks** turns it off, and says whether it is in use or why not.
- The remote desktop resizes to fit the window or screen, or runs at full Retina resolution.
- Full screen on the Mac hides the toolbar and menu bar until the pointer reaches the top edge.
- Remote audio with a jitter buffer and a mute button.

**Input**

- Keys are sent by physical position, so the remote layout decides what they type.
- Mouse with every button, smooth scrolling and a captured relative mode for games and 3D; the remote cursor is drawn locally.
- On iPad: hardware keyboards, trackpads and mice, plus touch in a direct or trackpad mode. Trackpad scrolling keeps coasting after a flick, as it does in iPadOS.
- On iPhone and iPad: the on-screen keyboard, with a key bar for arrows, Esc, Tab, sticky modifiers and system combinations such as Super+Tab.
- Up to four game controllers.

**Clipboard and files**

- Two-way text clipboard, off until you switch it on.
- Send files to the host: drop them on the picture, or use **Send Files…**. They land in the host user's download folder, never over an existing file, and Spectre says which folder.
- Files and folders copied on the host can be downloaded: to Downloads on the Mac, and to Spectre's folder in the Files app on iPad and iPhone.
- On the Mac, with the clipboard shared, a copy of files or folders on the host (up to 100 MB in all) goes straight onto the Mac's clipboard, so **Paste** in the Finder pastes the files themselves.
- On the Mac, files and folders copied in the Finder can be pasted on the remote desktop: the host reads them as the paste goes.
- Share a folder with the host, read-only, from the Mac: it shows up in the host's file manager, labelled with the Mac's name.
- Progress, cancelling and the results in a list of transfers. Needs a host with file transfer; see [Requirements](#requirements).

**On the Mac**

- A home window of your hosts with the last picture of each, and a window per session, so several can run at once.
- A toolbar for files, clipboard, mouse capture and mute, with the round trip and frame rate in its subtitle.
- A **Session** menu for files, mouse capture, clipboard and the key combinations macOS keeps for itself. No new shortcuts, so every key reaches the remote desktop.

**On iPad and iPhone**

- The remote desktop fills the screen; the controls float over it in Liquid Glass and fold into two corner buttons.
- A prompt panel: compose text with the system's input methods, dictation or paste, then send it to the host's cursor in one go.
- Voice input: hold the microphone key and speak; it is transcribed on the device and typed on the host.
- Pinch to magnify, or **Fill Screen**; the magnified picture follows the pointer.
- Region alerts: watch part of the screen, such as a terminal, and be told when it stops or starts changing.

**Languages:** English, Simplified Chinese, Traditional Chinese, Japanese and Spanish.

**Not done yet:** sending your microphone to the host (written, turned off for now), sending folders, and checking CA-issued certificates on iOS.

## Screenshots

| The home window on the Mac | A session on iPad |
|---|---|
| ![The home window on the Mac: hosts in the sidebar, the selected one's last picture and Connect](assets/macos-home.webp) | ![A GNOME desktop on iPad, sized to the iPad's screen, with the key bar open in the bottom-right corner](assets/ipad-session.webp) |

## Requirements

- A Mac with Apple silicon on macOS 27, or an iPhone or iPad on iOS or iPadOS 27
- A ghost host (ghostd and wraith); see [ghost](https://github.com/jsaiko/ghost) for setting one up
- For file transfer, a recent ghost (upstream `main` since October 2026). Pasting files copied here, and shared folders, also need a wraith built with libfuse3 3.12 or newer (`apt install libfuse3-dev` before building) on a host with `/dev/fuse` and `fusermount3`: the host mounts what Spectre offers. Without it, sending and downloading still work.
- For PyroWave, a wraith built with libpyrowave (ghost's `packaging/build-pyrowave.sh`, which pins the revision both ends must share) and `pyrowave = true` under `[encode.codecs]` in `/etc/ghost/wraith.toml`.

## Install

Download the notarized `.dmg` for the Mac from [GitHub Releases](https://github.com/pokoblin/spectre-apple/releases/latest) and drag Spectre to Applications. For iPhone and iPad, build from source.

## Usage

Add a server with **+**: its address (`host` or `host:port`, port 4442 by default), your user name and optionally your password. Then **Connect** and choose a desktop. On the first connection, confirm the server's certificate fingerprint.

On the Mac, each session opens in its own window; closing it disconnects and leaves the desktop running on the host. On iPad and iPhone the session covers the home screen.

**Files.** Drop files on the picture, or choose **Send Files…** (on the Mac in the toolbar and the Session menu, on iPad and iPhone under **More › Files**). The host saves them in its user's download folder (`~/Downloads`, or `[files] directory` in wraith.toml), as "name (1).ext" when the name is taken. When the host's user copies files or folders, Spectre offers to download them; with the clipboard shared, small copies (up to 100 MB in all) go straight onto the Mac's clipboard instead. On the Mac, with the clipboard shared, files and folders copied in the Finder can be pasted on the remote desktop, and **Session › Share Folder…** shares a folder with it, read-only and without hidden files, until you stop sharing it (**Session › Stop Sharing**, or the list of transfers) or quit Spectre. A shared folder is shared again whenever the session reconnects. Folders can't be sent with **Send Files…**.

**Keyboard on the Mac.** Cmd is sent as Super, so copy and paste on the remote desktop stay Ctrl+C and Ctrl+V. Only these shortcuts stay local:

| Shortcut | Action |
|---|---|
| Ctrl+Cmd+G | Capture or release the mouse |
| Ctrl+Cmd+F | Full screen |
| Cmd+Q | Quit |

**Touch on iPad and iPhone.** **More › Input Mode** switches between:

- **Trackpad** (default): one finger moves the cursor, tap to click.
- **Touch**: the pointer goes where you touch. Tap to click, long-press to right-click, drag with one finger, scroll with two, and tap with two or three fingers for a right or middle click.

## Building from source

You need Xcode 27 with the iOS 27 simulator runtime, [XcodeGen](https://github.com/yonaskolb/XcodeGen), `cmake` 3.25+ and `ninja` (`brew install cmake ninja`), and [vcpkg](https://github.com/microsoft/vcpkg), ideally at the commit upstream's CI uses:

```bash
git clone https://github.com/microsoft/vcpkg ~/src/vcpkg
```

```bash
git -C ~/src/vcpkg checkout 07f4812200df3d3c931c0c8a6081d3b21fe2bf9f
```

```bash
~/src/vcpkg/bootstrap-vcpkg.sh -disableMetrics
```

Set `VCPKG_ROOT` if vcpkg lives elsewhere.

1. Clone with the ghost submodule, which follows the [pokoblin/ghost](https://github.com/pokoblin/ghost) fork's `main` (upstream's). In an existing clone, run `git submodule sync && git submodule update --init`.

   ```bash
   git clone --recurse-submodules https://github.com/pokoblin/spectre-apple.git
   ```

2. Build `GDPCore.xcframework` (libgdp, its dependencies and a C bridge) into `Packages/GDPKit/Artifacts/`. The first run takes a few minutes; pass `macos`, `ios` or `ios-simulator` to build only those slices.

   ```bash
   scripts/build-gdpcore.sh
   ```

   Then build `PyroWave.xcframework` (the PyroWave codec's Metal port, from the `third_party/pyrowave` submodule) into `Packages/SpectreKit/Artifacts/`; this takes seconds.

   ```bash
   scripts/build-pyrowave.sh
   ```

3. Generate the Xcode project, then open `Spectre.xcodeproj` and run the `Spectre` scheme:

   ```bash
   xcodegen generate
   ```

   Or build the Mac app from the command line and copy it to Applications:

   ```bash
   xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=macOS,arch=arm64' -configuration Release -derivedDataPath build/DerivedData build
   ```

   ```bash
   ditto build/DerivedData/Build/Products/Release/Spectre.app /Applications/Spectre.app
   ```

For an iPhone or iPad, set your development team on the target in Xcode.

## Development

### Tests

```bash
swift test --package-path Packages/GDPKit
```

```bash
swift test --package-path Packages/SpectreKit
```

Both packages ship an in-process test host and lobby, so the end-to-end tests run over real QUIC on loopback. For the iPad simulator, run `xcodebuild test` in each package with `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'`.

### Running without a server

These options skip the login and play a generated 1080p60 test stream, with statistics on screen and on stdout:

- `--source loopback` (default): a test host inside the app, over a real GDP session on 127.0.0.1
- `--source direct`: straight to the decoder, no network
- `--connect HOST:PORT --token TOKEN --fingerprint SHA256`: a wraith started with a static token
- `--bench N`: measure for N seconds, print the results and quit

```bash
build/DerivedData/Build/Products/Release/Spectre.app/Contents/MacOS/Spectre --bench 60 --codec h265
```

Also: `--codec h264|h265|av1|pyrowave` (AV1 plays a bundled stream, where it decodes in hardware; PyroWave's is encoded on the spot by its Metal port, at about 250 Mbit/s), `--mode onArrival|displayLink`, `--in-flight N`, `--screen N`, `--rate HZ`, `--min-present-ms MS`, `--host-clipboard TEXT`.

For file transfer with the loopback host: `--send-file PATH` sends a file once the session starts, `--host-file PATH` has the test host's user copy one, a folder too (both can be given more than once), `--download-copied` downloads every copy, and `--download-dir DIR` puts downloads in `DIR`. `--host-fetch-copied` has the test host read every file copied here, as a paste would, and `--share-folder DIR` shares a folder once the session starts; the test host prints what it got and lists each share.

In the iOS simulator:

```bash
xcodebuild -project Spectre.xcodeproj -scheme Spectre -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0' -configuration Release -derivedDataPath build/DerivedData build
```

```bash
xcrun simctl install booted build/DerivedData/Build/Products/Release-iphonesimulator/Spectre.app
```

```bash
xcrun simctl launch --console-pty booted org.ghost.spectre.apple --source loopback
```

The simulator decodes in software, so its timings aren't comparable with a device.

### Project layout

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen project: one multiplatform app target |
| `App/` | The app: entry points, home screen, session UI, file transfer views, iPad and iPhone controls, icon |
| `Packages/GDPKit/` | The C bridge to libgdp and its Swift wrapper |
| `Packages/SpectreKit/` | Session, decoding, Metal presentation, input, clipboard, file transfers, login |
| `scripts/` | Builds the dependencies and the xcframeworks |
| `third_party/ghost/` | ghost as a submodule (pokoblin/ghost fork); only libgdp is built |
| `third_party/pyrowave/` | PyroWave as a submodule; only its Metal port (`metal/`) is built |

## Contributing

Issues and pull requests are welcome; please open an issue before larger changes.

- Write client code from the GDP specification (`third_party/ghost/docs/spec/gdp-spec.md`) and public standards. Most of upstream ghost is GPL-3.0, so don't copy or port from it, including its spectre client; only `libgdp/` and the specification are MIT.
- Run both packages' tests before sending a change.
- New interface text needs a translation for every language; `scripts/sync-strings.sh` updates the String Catalogs.

## Acknowledgements

spectre-apple is inspired by [ghost](https://github.com/jsaiko/ghost) by [Joseph Saiko](https://saiko.dev): the GDP protocol, the wraith host and the spectre client for Linux. It uses ghost's libgdp, follows its published specification and design documents, and borrows the name Spectre from the upstream client. Many thanks to the author for open-sourcing ghost and releasing libgdp and the specification under MIT; this project would not exist without them.

## License

[MIT](LICENSE).

- In upstream ghost, `libgdp/` and the specification are MIT and everything else is GPL-3.0-only. This project builds only `libgdp/`, and none of its code is copied or ported from the GPL parts.
- The app statically links ngtcp2, OpenSSL, Protocol Buffers, Abseil, zstd and PyroWave (MIT, Apache-2.0, BSD-3-Clause); their notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
