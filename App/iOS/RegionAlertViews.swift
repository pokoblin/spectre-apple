import SpectreKit
import SwiftUI

// The region alert's pieces of the session screen (docs/ipad-layout.md):
// choosing the region, its outline on the picture, the toolbar's bell, the
// dot on the toolbar's toggle and the banner of an alert.

/// Where the picture is in a layer laid over it: the same rectangle the
/// renderer draws into and touches are mapped through, magnified or not.
@MainActor private func mapping(_ size: CGSize, input: SessionInput, scale: CGFloat) -> PointerMapping {
    PointerMapping(viewSize: size, backingScale: scale, videoSize: input.videoSize, zoom: input.zoom)
}

// MARK: - Choosing the region

/// Over the whole picture while a region is chosen: dims it, and a drag
/// draws the rectangle. One smaller than 20 × 20 points is taken for a tap
/// and ignored; the picture takes no touches meanwhile.
struct RegionSelectionLayer: View {
    let regions: RegionAlertModel
    let input: SessionInput
    @Environment(\.displayScale) private var displayScale
    @State private var dragged: CGRect?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                if let dragged {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(uiColor: .systemBlue).opacity(0.15))
                        .stroke(Color(uiColor: .systemBlue), lineWidth: 2)
                        .frame(width: dragged.width, height: dragged.height)
                        .offset(x: dragged.minX, y: dragged.minY)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    dragged = CGRect(origin: drag.startLocation, size: .zero)
                        .union(CGRect(origin: drag.location, size: .zero))
                }
                .onEnded { _ in
                    defer { dragged = nil }
                    guard let dragged else { return }
                    let m = mapping(proxy.size, input: input, scale: displayScale)
                    if let region = m.region(of: dragged) { regions.select(region) }
                })
        }
        .accessibilityHidden(true)
    }
}

/// At the top while a region is chosen: what to do, and Cancel.
struct RegionSelectionHint: View {
    let regions: RegionAlertModel

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("Drag to frame the region to watch. Leave out the terminal's input line, where the cursor blinks.")
            } icon: {
                Image(systemName: "rectangle.dashed")
            }
            .font(.footnote)
            Button("Cancel", action: regions.cancelSelecting)
                .buttonStyle(.glass)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
        .dynamicTypeSize(...FloatingKeyBar.maxTypeSize)
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - The outline

/// The watched region on the picture, following it as it is magnified and
/// moved: dashed white while watching, dashed blue while it changes, solid
/// green just after an alert. Touches go through to the picture.
struct RegionOutline: View {
    let regions: RegionAlertModel
    let input: SessionInput
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            if let alert = regions.alert, let state = regions.state, !regions.isSelecting,
               input.videoSize.width > 0 {
                let rect = mapping(proxy.size, input: input, scale: displayScale).viewRect(of: alert.region)
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Self.color(state), style: Self.style(state))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .animation(.easeInOut(duration: 0.2), value: state)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func color(_ state: RegionWatcher.State) -> Color {
        switch state {
        case .watching: .white.opacity(0.7)
        case .changing: Color(uiColor: .systemBlue)
        case .alerted: Color(uiColor: .systemGreen)
        }
    }

    private static func style(_ state: RegionWatcher.State) -> StrokeStyle {
        state == .alerted ? StrokeStyle(lineWidth: 4) : StrokeStyle(lineWidth: 2, dash: [8, 5])
    }
}

// MARK: - The toolbar's bell

/// In the session toolbar: without a region, a bell that starts choosing
/// one; with one, a menu of when to alert, choosing it again and removing it.
struct RegionAlertKey: View {
    let regions: RegionAlertModel

    var body: some View {
        if let alert = regions.alert {
            Menu {
                Picker(selection: Binding(get: { alert.condition }, set: regions.setCondition)) {
                    Text("Stops Changing").tag(RegionWatcher.Condition.stopsChanging)
                    Text("Starts Changing").tag(RegionWatcher.Condition.startsChanging)
                } label: {
                    Label("Alert When", systemImage: "bell")
                }
                .pickerStyle(.menu)
                Picker(selection: Binding(get: { alert.stillSeconds }, set: regions.setStillSeconds)) {
                    ForEach(RegionAlert.stillChoices, id: \.self) { seconds in
                        Text(verbatim: RegionAlert.duration(seconds)).tag(seconds)
                    }
                } label: {
                    Label("Still For", systemImage: "timer")
                }
                .pickerStyle(.menu)
                Section {
                    Button("Select Region Again", systemImage: "rectangle.dashed", action: regions.startSelecting)
                    Button("Remove Region", systemImage: "trash", role: .destructive, action: regions.remove)
                }
            } label: {
                Image(systemName: "bell.fill")
                    .keyCap()
            }
            .menuIndicator(.hidden)
            .tint(.primary)
            .accessibilityLabel("Region Alert")
        } else {
            Button(action: regions.startSelecting) {
                Image(systemName: "bell")
            }
            .buttonStyle(KeyCapStyle())
            .accessibilityLabel("Select Region to Watch")
        }
    }
}

// MARK: - The toggle's dot

/// On the toolbar toggle's top-right: green while watching, the accent
/// color while the region changes, an orange bell just after an alert.
struct RegionStatusBadge: View {
    let state: RegionWatcher.State?

    var body: some View {
        Group {
            switch state {
            case .watching?:
                dot(.green)
            case .changing?:
                dot(.accentColor)
            case .alerted?:
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .transition(.scale.combined(with: .opacity))
            case nil:
                EmptyView()
            }
        }
        .offset(x: 2, y: -2)
        .animation(.easeInOut(duration: 0.2), value: state)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .stroke(.black.opacity(0.35), lineWidth: 1)
            .frame(width: 10, height: 10)
            .transition(.opacity)
    }
}

// MARK: - The banner

/// At the top when the region alerts, tinted green; a tap puts it away.
struct RegionAlertBanner: View {
    let condition: RegionWatcher.Condition
    let dismiss: () -> Void

    var body: some View {
        Button(action: dismiss) {
            Label {
                Text(RegionAlertModel.message(condition))
            } icon: {
                Image(systemName: "bell.badge.fill")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(FloatingKeyBar.noticePadding)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.green.opacity(0.6)).interactive(), in: .capsule)
        .accessibilityHint("Dismisses the alert")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
