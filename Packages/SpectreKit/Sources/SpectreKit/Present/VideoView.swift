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
    let input: SessionInput?

    public init(presenter: VideoPresenter, input: SessionInput? = nil) {
        self.presenter = presenter
        self.input = input
    }

    public func makeUIView(context: Context) -> IOSSessionView {
        let view = IOSSessionView(frame: .zero, device: presenter.renderer.device)
        presenter.attach(view)
        view.input = input
        return view
    }

    public func updateUIView(_ view: IOSSessionView, context: Context) {
        view.input = input
    }
}
#endif
