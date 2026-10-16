import SpectreKit
import SwiftUI

/// The glass over a session's picture, on iPad, iPhone and the Mac.
enum SessionGlass {
    /// Large glass cards: the connection status, the prompt panel.
    static let cardCornerRadius: CGFloat = 28
    /// Small notices at the top of the picture.
    static let noticePadding = EdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
}

/// What the session's connection is doing, over the picture
/// (docs/ipad-layout.md, docs/macos-layout.md): connecting, couldn't
/// connect, reconnecting.
struct SessionStatusOverlay: View {
    let model: PlaybackModel

    var body: some View {
        switch model.phase {
        case .idle, .connecting:
            if model.isRemoteSession {
                dimmed(0.5) {
                    SessionStatusCard(symbol: "pc", pulses: true,
                                      title: Text("Connecting to “\(model.title)”…")) {
                        Button("Cancel") { model.disconnect() }
                            .buttonStyle(.glass)
                    }
                }
            }
        case let .failed(message):
            dimmed(0.5) {
                SessionStatusCard(symbol: "exclamationmark.triangle.fill", symbolColor: .yellow,
                                  title: model.title.isEmpty ? Text("Couldn't Connect")
                                                             : Text("Couldn't connect to “\(model.title)”"),
                                  message: message) {
                    if model.canClose {
                        Button("Close") { model.closeFailure() }
                            .buttonStyle(.glass)
                    }
                    if model.canRetry {
                        Button("Retry") { model.retry() }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
        case let .reconnecting(attempt, _, _):
            // The last picture stays, dimmed, and takes no touches meanwhile.
            dimmed(0.35) {
                ReconnectingCapsule(attempt: attempt) { model.cancelReconnect() }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 40)
            }
        case .encoding, .playing:
            EmptyView()
        }
    }

    /// The whole screen darkened (and kept from the picture's gestures) under `content`.
    private func dimmed(_ opacity: Double, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            Color.black.opacity(opacity)
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture {} // touches and clicks stop here, not on the old picture
            content()
                .padding(.horizontal, 16)
        }
        .transition(.opacity)
    }
}

/// A glass card in the middle of the screen: a symbol, a title, an
/// optional message and a row of buttons.
struct SessionStatusCard<Buttons: View>: View {
    var symbol: String
    var symbolColor: Color = .secondary
    var pulses = false
    var title: Text
    var message: String?
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(symbolColor)
                .symbolEffect(.pulse, isActive: pulses)
                .accessibilityHidden(true)
            title
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let message, !message.isEmpty {
                // The host's or the transport's own words: not translated.
                Text(verbatim: message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) { buttons() }
                .padding(.top, 4)
                #if os(macOS)
                .controlSize(.large) // the Mac's are small by default
                #endif
        }
        .padding(28)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: SessionGlass.cardCornerRadius))
        .accessibilityElement(children: .contain)
    }
}

/// At the bottom while a lost connection is being restored.
struct ReconnectingCapsule: View {
    let attempt: Int
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Connection lost. Reconnecting (attempt \(attempt))…")
                .font(.footnote)
            Button("Cancel", action: cancel)
                .buttonStyle(.glass)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Notices

/// Short notices at the top centre of the picture (the iPad's bottom
/// corners are the controls', the Mac's window has its toolbar above):
/// clipboard text that crossed, characters the host's layout can't type.
/// They fade in and out and take no touches.
struct TopNotices: View {
    let model: PlaybackModel
    #if os(iOS)
    let regions: RegionAlertModel
    /// The region alert shown (its count), on top of the others.
    @State private var regionAlert: Int?
    #endif
    @State private var clipboard: ClipboardSync.Transfer.Direction?
    @State private var untypable: Int?

    var body: some View {
        VStack(spacing: 8) {
            #if os(iOS)
            // First, at the top; a clipboard notice at the same time comes
            // below it (12 + 36 + 8: at 56).
            if regionAlert != nil {
                RegionAlertBanner(condition: regions.lastAlert) {
                    regions.dismissAlert()
                    withAnimation(.easeInOut(duration: 0.2)) { regionAlert = nil }
                }
            }
            #endif
            Group {
                if let clipboard {
                    Notice(symbol: "doc.on.clipboard",
                           text: clipboard == .fromHost ? Text("Copied from the host") : Text("Sent to the host's clipboard"))
                }
                if let untypable {
                    Notice(symbol: "character.cursor.ibeam",
                           text: Text("\(untypable) characters can't be typed on the host's US layout. Use the host's input method for other scripts."))
                }
            }
            .allowsHitTesting(false)
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .task(id: regions.alertCount) {
            guard regions.alertCount > 0 else { return }
            await show(regions.alertCount, in: $regionAlert, for: .seconds(RegionWatcher.alertedDuration))
        }
        #endif
        .task(id: model.clipboard?.lastTransfer) {
            guard let transfer = model.clipboard?.lastTransfer else { return }
            await show(transfer.direction, in: $clipboard, for: .seconds(2))
        }
        .task(id: model.input?.untypable) {
            guard let notice = model.input?.untypable else { return }
            await show(notice.count, in: $untypable, for: .seconds(3))
        }
    }

    private func show<T: Equatable>(_ value: T, in slot: Binding<T?>, for duration: Duration) async {
        withAnimation(.easeInOut(duration: 0.2)) { slot.wrappedValue = value }
        guard (try? await Task.sleep(for: duration)) != nil else { return }
        withAnimation(.easeInOut(duration: 0.2)) { if slot.wrappedValue == value { slot.wrappedValue = nil } }
    }
}

private struct Notice: View {
    let symbol: String
    let text: Text

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(SessionGlass.noticePadding)
            .glassEffect(.regular, in: .capsule)
            .transition(.opacity)
    }
}
