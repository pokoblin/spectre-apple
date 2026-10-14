import MetalKit
import SwiftUI

/// The video surface for SwiftUI: an `MTKView` driven by a ``VideoPresenter``,
/// which with a ``SessionInput`` also takes the session's input.
#if os(macOS)
public struct VideoView: NSViewRepresentable {
    let presenter: VideoPresenter
    let input: SessionInput?

    public init(presenter: VideoPresenter, input: SessionInput? = nil) {
        self.presenter = presenter
        self.input = input
    }

    public func makeNSView(context: Context) -> MacSessionView {
        let view = MacSessionView(frame: .zero, device: presenter.renderer.device)
        presenter.attach(view)
        view.input = input
        return view
    }

    public func updateNSView(_ view: MacSessionView, context: Context) {
        view.input = input
    }
}
#else
public struct VideoView: UIViewRepresentable {
    let presenter: VideoPresenter

    public init(presenter: VideoPresenter) { self.presenter = presenter }

    public func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: presenter.renderer.device)
        presenter.attach(view)
        return view
    }

    public func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
