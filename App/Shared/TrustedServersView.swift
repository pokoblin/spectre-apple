import SpectreKit
import SwiftUI

/// The servers whose certificate the user trusted on first connection
/// (gdp-spec.md §2.3), with their fingerprints; forgetting one makes its
/// next connection ask again.
struct TrustedServersView: View {
    @Bindable var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TrustedServersList(app: app)
                .navigationTitle("Trusted Servers")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 520, idealHeight: 600)
        #endif
    }
}

/// The trusted servers themselves: the sheet's content on iPad and iPhone,
/// a page of Settings on the Mac.
struct TrustedServersList: View {
    @Bindable var app: AppModel
    @State private var forgetting: KnownHosts.Pin?

    var body: some View {
        Group {
            if app.trustedServers.isEmpty {
                ContentUnavailableView {
                    Label("No Trusted Servers", systemImage: "lock.shield")
                } description: {
                    Text("Servers you trust on their first connection appear here. A server whose certificate comes from a certificate authority isn't listed: nothing is saved for it.")
                }
            } else {
                List(app.trustedServers) { pin in
                    row(pin)
                        .contextMenu {
                            Button("Forget", role: .destructive) { forgetting = pin }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button("Forget", role: .destructive) { forgetting = pin }
                        }
                        #endif
                }
            }
        }
        // An alert, not a confirmation dialog: on iPad a dialog is a popover,
        // and one shown for a row's swipe action dismissed the whole sheet.
        .alert("Forget the saved fingerprint?", isPresented: asking, presenting: forgetting) { pin in
            Button("Forget", role: .destructive) { app.forgetTrusted(pin) }
            Button("Cancel", role: .cancel) {}
        } message: { pin in
            Text("The next connection to \(pin.server.description) will ask you to trust it again.")
        }
    }

    private func row(_ pin: KnownHosts.Pin) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: pin.server.description).font(.headline)
                Text(verbatim: "SHA-256").font(.caption).foregroundStyle(.secondary)
                FingerprintText(fingerprint: pin.fingerprint)
            }
            #if os(macOS)
            Spacer()
            Button(role: .destructive) { forgetting = pin } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Forget the saved fingerprint")
            .accessibilityLabel("Forget \(pin.server.description)")
            #endif
        }
        .padding(.vertical, 4)
    }

    private var asking: Binding<Bool> {
        Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } })
    }
}
