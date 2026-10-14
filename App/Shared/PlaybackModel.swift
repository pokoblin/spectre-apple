import Foundation
#if os(macOS)
import AppKit
#endif
import Observation
import SpectreKit

/// Drives the prototype's video path: encodes a test stream, plays it
/// through VideoToolbox into the Metal view, and reports timings once a
/// second (and, with `--bench`, a summary over a fixed run before exiting).
@MainActor
@Observable
final class PlaybackModel {
    enum Phase: Equatable {
        case idle
        case encoding(VideoCodec, Double)
        case playing(VideoCodec)
        case failed(String)
    }

    struct BenchOptions {
        var seconds: Double
        var warmup: Double = 2
    }

    private(set) var phase = Phase.idle
    private(set) var statsText = ""
    private(set) var streamInfo = ""
    var codec: VideoCodec = .h264 {
        // Only a user's change replays; init's assignment comes before start().
        didSet { if codec != oldValue, phase != .idle { Task { await play(codec) } } }
    }
    var mode: VideoPresenter.Mode = .onArrival {
        didSet { presenter?.mode = mode; stats.reset() }
    }

    let presenter: VideoPresenter?
    private let mailbox = FrameMailbox()
    private let stats: PlaybackStats
    private var player: StreamPlayer?
    private var streams: [VideoCodec: TestStream] = [:]
    private var ticker: Task<Void, Never>?
    private let bench: BenchOptions?

    init(arguments: [String] = CommandLine.arguments) {
        stats = PlaybackStats(mailbox: mailbox)
        var presenter: VideoPresenter?
        var failure: String?
        do {
            presenter = VideoPresenter(renderer: try VideoRenderer(), mailbox: mailbox, stats: stats)
        } catch {
            failure = String(describing: error)
        }
        self.presenter = presenter

        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        bench = value("--bench").flatMap(Double.init).map { BenchOptions(seconds: $0) }
        if let c = value("--codec").flatMap(VideoCodec.init(rawValue:)) { codec = c }
        if let m = value("--mode").flatMap(VideoPresenter.Mode.init(rawValue:)) {
            mode = m
            presenter?.mode = m
        }
        if let rate = value("--rate").flatMap(Int.init) { presenter?.displayLinkRate = rate }
        if let ms = value("--min-present-ms").flatMap(Double.init) { presenter?.minimumPresentDuration = ms / 1000 }
        if let failure { phase = .failed(failure) }
    }

    func start() async {
        guard presenter != nil, phase == .idle else { return }
        #if os(macOS)
        if bench != nil {
            // A run started from a terminal opens behind it; an occluded
            // window's drawables are never presented, which would void the run.
            NSApplication.shared.activate()
            NSApplication.shared.windows.first?.level = .floating
        }
        #endif
        await play(codec)
    }

    private func play(_ codec: VideoCodec) async {
        player?.stop()
        player = nil
        let stream: TestStream
        if let cached = streams[codec] {
            stream = cached
        } else {
            phase = .encoding(codec, 0)
            let progress: @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor in
                    if case .encoding = self?.phase { self?.phase = .encoding(codec, p) }
                }
            }
            do {
                stream = try await Task.detached(priority: .userInitiated) {
                    try TestStreamEncoder.encode(codec: codec, progress: progress)
                }.value
            } catch {
                phase = .failed("encode \(codec.displayName): \(error)")
                return
            }
            streams[codec] = stream
        }
        guard codec == self.codec, let presenter else { return }
        streamInfo = String(format: "%@ %d×%d@%d, %d frames, %.1f Mb/s", codec.displayName, stream.width, stream.height,
                            stream.framesPerSecond, stream.accessUnits.count, stream.averageBitrate / 1e6)
        print("stream: \(streamInfo)")
        presenter.displaySize = CGSize(width: stream.width, height: stream.height)
        let player = StreamPlayer(stream: stream, mailbox: mailbox, stats: stats) { [presenter] in
            presenter.frameAvailable()
        }
        self.player = player
        stats.reset()
        player.start()
        phase = .playing(codec)
        startTicker()
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            if let bench = self?.bench {
                do {
                    try await Task.sleep(for: .seconds(bench.warmup))
                    self?.stats.reset()
                    for second in 1...Int(bench.seconds.rounded(.up)) {
                        try await Task.sleep(for: .seconds(1))
                        self?.benchProgress(second)
                    }
                } catch {
                    return // replaced by a newer run
                }
                self?.finishBench()
                return
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let summary = stats.summary()
                stats.reset()
                statsText = Self.overlay(summary, mode: mode)
                print(String(format: "decode p50 %.2f / max %.2f ms, decode→present p50 %.2f / max %.2f ms, "
                    + "gpu %.2f ms, %.1f fps shown, replaced %llu, zero-copy %d/%d, cpu %.1f%%",
                    summary.decode.p50, summary.decode.max, summary.present.p50, summary.present.max,
                    summary.gpu.mean, summary.presentedFPS, summary.replacedFrames, summary.zeroCopyFrames,
                    summary.presentedFrames + summary.unpresentedFrames, summary.cpuPercent))
            }
        }
    }

    private func benchProgress(_ second: Int) {
        let s = stats.summary()
        var visibility = ""
        #if os(macOS)
        if let window = NSApplication.shared.windows.first {
            visibility = window.occlusionState.contains(.visible) ? ", window visible" : ", window OCCLUDED"
        }
        #endif
        print(String(format: "  [%2d s] decoded %d, presented %d, not presented %d%@", second, s.decodedFrames,
                     s.presentedFrames, s.unpresentedFrames, visibility))
    }

    private func finishBench() {
        let summary = stats.summary()
        print("=== bench: \(streamInfo), mode \(mode.rawValue), display link \(presenter?.displayLinkRate ?? 0) Hz, min present \(presenter?.minimumPresentDuration.map { "\($0 * 1000) ms" } ?? "-") ===")
        print(summary)
        fflush(stdout)
        exit(0)
    }

    private static func overlay(_ s: PlaybackStats.Summary, mode: VideoPresenter.Mode) -> String {
        """
        \(String(format: "%.0f fps decoded, %.0f fps shown (%@)", s.decodedFPS, s.presentedFPS, mode.rawValue))
        \(String(format: "decode %.2f ms (max %.2f)%@", s.decode.p50, s.decode.max, s.hardwareDecoder ? ", hardware" : ""))
        \(String(format: "decode→present %.2f ms (max %.2f)", s.present.p50, s.present.max))
        \(String(format: "gpu %.2f ms, interval %.2f ms (max %.2f)", s.gpu.mean, s.presentInterval.p50, s.presentInterval.max))
        \(String(format: "zero-copy %d/%d, replaced %llu, cpu %.1f%%", s.zeroCopyFrames, s.presentedFrames + s.unpresentedFrames, s.replacedFrames, s.cpuPercent))
        """
    }
}
