import SpectreKit
import SwiftUI
import UIKit

/// The remote desktop on iOS, filling the screen, with the key bar of the
/// bottom-right corner on it (docs/ipad-layout.md).
struct RemoteScreen: UIViewControllerRepresentable {
    let presenter: VideoPresenter
    let input: SessionInput?
    let keyBar: KeyBarModel

    func makeUIViewController(context: Context) -> RemoteScreenController {
        RemoteScreenController(presenter: presenter, keyBar: keyBar)
    }

    func updateUIViewController(_ controller: RemoteScreenController, context: Context) {
        controller.sessionView.input = input
    }
}

/// The picture and, over it, the key bar's three pieces, each in its own
/// hosting controller only as large as what it shows: the toggle, the
/// column above it and the row to its left, pinned to the safe area's
/// bottom-right corner with Auto Layout. Touches anywhere else, in the
/// gaps of the L included, reach the picture. One SwiftUI layer over the
/// whole screen would hit-test as a whole and take the picture's gestures.
/// A closed bar takes no touches at all.
final class RemoteScreenController: UIViewController {
    let sessionView: IOSSessionView
    private let keyBar: KeyBarModel
    private var toggle: UIHostingController<KeyBarToggle>!
    private var column: UIHostingController<FloatingKeyColumn>!
    private var row: UIHostingController<FloatingKeyRow>!
    /// The row's leftmost position: past the session toolbar.
    private var rowLeading: NSLayoutConstraint!

    init(presenter: VideoPresenter, keyBar: KeyBarModel) {
        sessionView = IOSSessionView(frame: .zero, device: presenter.renderer.device)
        presenter.attach(sessionView)
        self.keyBar = keyBar
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        sessionView.frame = view.bounds
        sessionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sessionView)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Made the first time the keyboard shows: made here, a keyboard-style
        // input view stopped the picture from being drawn at all (0 fps
        // shown) and left a white strip where the status bar was.
        sessionView.makeKeyboardAccessory = { [keyBar] in KeyboardAccessory(model: keyBar) }
        toggle = host(KeyBarToggle(model: keyBar))
        column = host(FloatingKeyColumn(model: keyBar))
        row = host(FloatingKeyRow(model: keyBar))
        // The bars give way to the space there is (they scroll instead).
        column.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        row.view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let safe = view.safeAreaLayoutGuide
        let margin = FloatingKeyBar.margin, spacing = FloatingKeyBar.spacing
        rowLeading = row.view.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor)
        NSLayoutConstraint.activate([
            toggle.view.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -margin),
            toggle.view.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -margin),

            column.view.centerXAnchor.constraint(equalTo: toggle.view.centerXAnchor),
            column.view.bottomAnchor.constraint(equalTo: toggle.view.topAnchor, constant: -spacing),
            column.view.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: margin),

            row.view.centerYAnchor.constraint(equalTo: toggle.view.centerYAnchor),
            row.view.trailingAnchor.constraint(equalTo: toggle.view.leadingAnchor, constant: -spacing),
            row.view.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: margin),
            rowLeading,
        ])
        track()
    }

    private func host<Content: View>(_ content: Content) -> UIHostingController<Content> {
        let controller = UIHostingController(rootView: content)
        controller.sizingOptions = .intrinsicContentSize
        controller.view.backgroundColor = .clear
        controller.overrideUserInterfaceStyle = .dark
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(controller)
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        return controller
    }

    /// Follows the model: what is shown, what takes touches, where the row may reach.
    private func track() {
        withObservationTracking {
            apply()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func apply() {
        let visible = keyBar.isVisible
        let open = visible && keyBar.isExpanded
        toggle.view.isHidden = !visible
        column.view.isHidden = !visible
        row.view.isHidden = !visible
        column.view.isUserInteractionEnabled = open
        row.view.isUserInteractionEnabled = open
        rowLeading.constant = keyBar.leadingObstruction + FloatingKeyBar.spacing
    }
}
