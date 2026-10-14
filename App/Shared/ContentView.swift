import SpectreKit
import SwiftUI

struct ContentView: View {
    @State private var model = PlaybackModel()
    @State private var diagnostics = DiagnosticsModel()

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let presenter = model.presenter {
                VideoView(presenter: presenter)
                    .ignoresSafeArea()
            }
            overlay
                .padding(10)
        }
        #if os(macOS)
        .toolbar {
            ToolbarItemGroup { controls }
        }
        #endif
        .task { await model.start() }
        .task { await diagnostics.run() }
    }

    @ViewBuilder private var controls: some View {
        Picker("Codec", selection: $model.codec) {
            ForEach(VideoCodec.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Pacing", selection: $model.mode) {
            Text("On arrival").tag(VideoPresenter.Mode.onArrival)
            Text("Display link").tag(VideoPresenter.Mode.displayLink)
        }
    }

    @ViewBuilder private var overlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(iOS)
            HStack { controls }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            #endif
            switch model.phase {
            case .idle:
                EmptyView()
            case let .encoding(codec, progress):
                ProgressView("Encoding \(codec.displayName) test stream…", value: progress)
                    .frame(width: 280)
            case .playing:
                Text(model.streamInfo)
                Text(model.statsText)
            case let .failed(message):
                Text(message).foregroundStyle(.red)
            }
            ForEach(diagnostics.lines, id: \.self) { Text($0) }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }
}
