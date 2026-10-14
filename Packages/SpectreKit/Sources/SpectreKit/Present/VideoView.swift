import MetalKit
import SwiftUI

/// The video surface for SwiftUI: an `MTKView` driven by a ``VideoPresenter``.
#if os(macOS)
public struct VideoView: NSViewRepresentable {
    let presenter: VideoPresenter

    public init(presenter: VideoPresenter) { self.presenter = presenter }

    public func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: presenter.renderer.device)
        presenter.attach(view)
        return view
    }

    public func updateNSView(_ view: MTKView, context: Context) {}
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
