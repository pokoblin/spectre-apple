import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Spectre's thanks to ghost and its links: the credits of the Mac's About
/// panel, and About Spectre on iPad and iPhone (docs/macos-layout.md,
/// docs/ipad-layout.md).
enum Credits {
    static let ghost = URL(string: "https://github.com/jsaiko/ghost")!
    static let sourceCode = URL(string: "https://github.com/pokoblin/spectre-apple")!
    static let license = URL(string: "https://github.com/pokoblin/spectre-apple/blob/main/LICENSE")!
    static let notices = URL(string: "https://github.com/pokoblin/spectre-apple/blob/main/THIRD_PARTY_NOTICES.md")!

    /// The README's acknowledgement, shortened; ghost and its author are links.
    static var thanks: AttributedString {
        AttributedString(localized: "Spectre is inspired by [ghost](https://github.com/jsaiko/ghost) by [Joseph Saiko](https://saiko.dev). It uses ghost's libgdp and follows its published specification. Many thanks to the author for open-sourcing ghost and releasing libgdp and the specification under MIT.")
    }

    static var independence: AttributedString {
        AttributedString(localized: "Spectre is an independent, third-party client, not part of the ghost project.")
    }

    /// The links after the thanks, as the iOS page lists them.
    static var links: [(title: LocalizedStringResource, url: URL)] {
        [("ghost on GitHub", ghost), ("Source Code", sourceCode), ("License", license), ("Third-Party Notices", notices)]
    }

    /// "Version 0.6.1 (16)", as the Mac's About panel puts it.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
    }

    #if os(macOS)
    /// The About panel's credits: the thanks, the independence and the
    /// links, centred in the panel's small type.
    static var panelCredits: NSAttributedString {
        var text = thanks
        text += AttributedString("\n\n")
        text += independence
        text += AttributedString("\n\n")
        for (index, link) in links.dropFirst().enumerated() {
            if index > 0 { text += AttributedString(" · ") }
            var item = AttributedString(localized: link.title)
            item.link = link.url
            text += item
        }
        let credits = NSMutableAttributedString(text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let whole = NSRange(location: 0, length: credits.length)
        credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                               .foregroundColor: NSColor.labelColor,
                               .paragraphStyle: paragraph], range: whole)
        return credits
    }

    /// The app menu's About Spectre: the system's panel, with the credits.
    @MainActor static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: panelCredits])
    }
    #endif
}

#if os(iOS)
/// About Spectre, from the home screen's menu: the version, the thanks to
/// ghost and the project's links.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                FormHeader(symbol: "info.circle", title: Text(verbatim: "Spectre"), message: Text(verbatim: Credits.version))
                Section {
                    Text(Credits.thanks)
                    Text(Credits.independence)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Thanks")
                }
                Section {
                    ForEach(Credits.links, id: \.url) { link in
                        Link(destination: link.url) {
                            Label { Text(link.title) } icon: { Image(systemName: "arrow.up.right.square") }
                        }
                    }
                }
            }
            .navigationTitle("About Spectre")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif
