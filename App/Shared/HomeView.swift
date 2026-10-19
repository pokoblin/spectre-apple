import SpectreKit
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

typealias SavedHost = AppModel.SavedHost

/// The home screen (docs/ipad-layout.md, docs/macos-layout.md): hosts in a
/// sidebar, the selected one's details. On iPad and iPhone the session
/// covers it in full screen, and it collapses to one column in a narrow
/// window; on the Mac it is a window of its own and each session opens in
/// another.
struct HomeView: View {
    @Bindable var app: AppModel
    @State private var selection: SavedHost.ID?
    @State private var editing: SavedHost?
    #if os(iOS)
    @State private var showsAbout = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCollapsed: Bool { sizeClass == .compact }
    #else
    @Environment(\.openWindow) private var openWindow
    private let isCollapsed = false
    #endif

    var body: some View {
        NavigationSplitView {
            // The sidebar column is always compact itself: the window's size class decides.
            HostSidebar(app: app, selection: $selection, isCollapsed: isCollapsed,
                        edit: { editing = $0 }, add: addHost, showTrustedServers: { app.showsTrustedServers = true },
                        showAbout: showAbout)
                .sheet(item: $editing) { host in
                    HostEditor(host: host, isNew: app.host(host.id) == nil,
                               hasSavedPassword: app.hasSavedPassword(host)) { saved, password, remember in
                        app.saveHost(saved, password: password, remember: remember)
                        selection = saved.id
                    }
                }
        } detail: {
            Group {
                if let host = app.host(selection) {
                    HostDetail(app: app, host: host, edit: { editing = $0 })
                } else if app.hosts.isEmpty {
                    GettingStarted(add: addHost)
                } else {
                    ContentUnavailableView("Select a Host", systemImage: "pc",
                                           description: Text("Choose the host to connect to in the sidebar."))
                }
            }
            .sheet(isPresented: $app.showsTrustedServers) { TrustedServersView(app: app) }
            #if os(iOS)
            .sheet(isPresented: $showsAbout) { AboutView() }
            #endif
        }
        .sheet(isPresented: Binding(get: { app.loginHost != nil && !isCoveredBySession },
                                    set: { if !$0, app.loginHost != nil { app.cancelLogin() } })) {
            if let host = app.host(app.loginHost) {
                LoginSheet(app: app, host: host)
            }
        }
        #if os(iOS)
        .fullScreenCover(item: Binding(get: { session }, set: { _ in })) { item in
            SessionView(model: item.model)
                .id(item.id)
        }
        .onChange(of: sizeClass) { selectFirstIfWide() }
        #else
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            app.onSessionOpened = { [openWindow] id in openWindow(value: id) }
            app.onShowHome = { [openWindow] in openWindow(id: SpectreApp.homeWindow) }
            // Sessions from the command line, already open at launch.
            for session in app.sessions { openWindow(value: session.id) }
        }
        #endif
        .onAppear(perform: selectFirstIfWide)
        .onChange(of: app.hosts.map(\.id)) { selectFirstIfWide() }
    }

    /// iOS: a session covers the home screen, and its sheets wait. On the
    /// Mac sessions have windows of their own.
    private var isCoveredBySession: Bool {
        #if os(iOS)
        session != nil
        #else
        false
        #endif
    }

    /// The session being shown, as the cover's item.
    private var session: SessionItem? {
        if case let .session(model) = app.screen { SessionItem(model: model) } else { nil }
    }

    private func addHost() {
        editing = SavedHost(server: "", username: "")
    }

    /// iOS: About Spectre's sheet. The Mac has the system's About panel.
    private func showAbout() {
        #if os(iOS)
        showsAbout = true
        #endif
    }

    /// Side by side, the detail column is never left empty; collapsed,
    /// selecting would push straight into a host.
    private func selectFirstIfWide() {
        if let selection, app.host(selection) == nil { self.selection = nil }
        guard !isCollapsed, selection == nil else { return }
        selection = HostSidebar.recent(app.hosts).first?.id ?? HostSidebar.saved(app.hosts).first?.id
    }
}

struct SessionItem: Identifiable {
    let model: PlaybackModel
    var id: ObjectIdentifier { ObjectIdentifier(model) }
}

// MARK: - Sidebar

struct HostSidebar: View {
    @Bindable var app: AppModel
    @Binding var selection: SavedHost.ID?
    /// One column: no detail beside the sidebar.
    let isCollapsed: Bool
    let edit: (SavedHost) -> Void
    let add: () -> Void
    let showTrustedServers: () -> Void
    let showAbout: () -> Void

    /// The three connected last, latest first.
    static func recent(_ hosts: [SavedHost]) -> [SavedHost] {
        Array(hosts.filter { $0.lastConnected != nil }
            .sorted { $0.lastConnected! > $1.lastConnected! }
            .prefix(3))
    }

    /// The others, by name.
    static func saved(_ hosts: [SavedHost]) -> [SavedHost] {
        let recentIDs = Set(recent(hosts).map(\.id))
        return hosts.filter { !recentIDs.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List(selection: $selection) {
            if app.hosts.isEmpty && isCollapsed {
                // No detail column to show it in.
                Section("Get Started") {
                    GettingStartedSteps()
                        .padding(.vertical, 4)
                }
            }
            let recent = Self.recent(app.hosts)
            if !recent.isEmpty {
                Section("Recent") { ForEach(recent) { row($0) } }
            }
            let saved = Self.saved(app.hosts)
            if !saved.isEmpty {
                Section("Saved") { ForEach(saved) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(Text(verbatim: "Spectre"))
        #if os(macOS)
        // Room for the toolbar's buttons above it, and for the account.
        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        #endif
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .primaryAction) {
                Button(action: add) { Label("Add Server", systemImage: "plus") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(action: showTrustedServers) { Label("Trusted Servers…", systemImage: "lock.shield") }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(action: showAbout) { Label("About Spectre", systemImage: "info.circle") }
            }
            #else
            // Above the sidebar, beside its toggle; Trusted Servers is a page of Settings.
            ToolbarItem {
                Button(action: add) { Label("Add Server", systemImage: "plus") }
            }
            #endif
        }
    }

    private func row(_ host: SavedHost) -> some View {
        HostRow(host: host)
            .contextMenu {
                Button { app.connect(host) } label: { Label("Connect", systemImage: "play.fill") }
                Button { edit(host) } label: { Label("Edit", systemImage: "pencil") }
                if app.hasSavedPassword(host) {
                    Button { app.forgetPassword(host) } label: { Label("Forget Password", systemImage: "key.slash") }
                }
                Button(role: .destructive) { app.deleteHost(host) } label: { Label("Delete", systemImage: "trash") }
            }
    }
}

struct HostRow: View {
    let host: SavedHost

    var body: some View {
        Label {
            HStack {
                titles
                #if os(iOS)
                if RegionAlertStore.shared[host: host.id] != nil {
                    Spacer()
                    Image(systemName: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Region Alert")
                }
                #endif
            }
        } icon: {
            Image(systemName: "pc")
        }
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: host.title).lineLimit(1)
            TimelineView(.everyMinute) { _ in
                Group {
                    if let last = host.lastConnected {
                        Text(last.formatted(.relative(presentation: .named)))
                    } else {
                        Text(verbatim: host.account)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

// MARK: - Detail

struct HostDetail: View {
    @Bindable var app: AppModel
    let host: SavedHost
    let edit: (SavedHost) -> Void
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                thumbnail
                VStack(spacing: 6) {
                    Text(verbatim: host.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(verbatim: host.account)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    Button { app.connect(host) } label: {
                        Label("Connect", systemImage: "play.fill")
                            .font(.title3.weight(.semibold))
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    if app.sessionHost == host.id, let ended = app.lastSessionEnd {
                        // Why its last session ended, as the session put it.
                        Text(verbatim: ended)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                infoCard
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle("")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { edit(host) } label: { Label("Edit", systemImage: "pencil") }
                    if app.hasSavedPassword(host) {
                        Button { app.forgetPassword(host) } label: { Label("Forget Password", systemImage: "key.slash") }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog(Text("Delete “\(host.title)”?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { app.deleteHost(host) }
        } message: {
            Text("Its saved password and last picture are deleted too.")
        }
    }

    /// The last picture of its remote desktop, kept on this device.
    private var thumbnail: some View {
        let path = AppModel.thumbnailURL(host.id).path()
        #if os(iOS)
        let image = app.thumbnailRevision >= 0 ? UIImage(contentsOfFile: path).map(Image.init(uiImage:)) : nil
        #else
        let image = app.thumbnailRevision >= 0 ? NSImage(contentsOfFile: path).map(Image.init(nsImage:)) : nil
        #endif
        // The image goes in an overlay, so its own size can't widen the page.
        return Rectangle()
            .fill(.quaternary)
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "pc")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 520)
            .clipShape(.rect(cornerRadius: 20))
            .accessibilityHidden(true)
    }

    private var infoCard: some View {
        VStack(spacing: 0) {
            infoRow("Last Connected") {
                if let last = host.lastConnected {
                    Text(last.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("Never")
                }
            }
            Divider().padding(.leading, 16)
            infoRow("Password") {
                if app.hasSavedPassword(host) {
                    Text("Saved in Keychain")
                } else if app.hasSessionPassword(host) {
                    Text("Until Spectre Quits")
                } else {
                    Text("Not Saved")
                }
            }
            #if os(iOS)
            Divider().padding(.leading, 16)
            infoRow("Region Alert") {
                switch RegionAlertStore.shared[host: host.id] {
                case let alert? where alert.condition == .stopsChanging:
                    Text("When it stops changing for \(RegionAlert.duration(alert.stillSeconds))")
                case let alert?:
                    Text("When it starts changing after \(RegionAlert.duration(alert.stillSeconds)) still")
                case nil:
                    Text("Off")
                }
            }
            #endif
        }
        .frame(maxWidth: 520)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    private func infoRow(_ title: LocalizedStringKey, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(title)
            Spacer()
            value().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Empty

struct GettingStarted: View {
    let add: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Get Started", systemImage: "pc")
        } description: {
            GettingStartedSteps()
                .frame(maxWidth: 460)
        } actions: {
            Button(action: add) { Label("Add Server", systemImage: "plus") }
                .buttonStyle(.glassProminent)
        }
    }
}

struct GettingStartedSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            step(1, "Set up ghost on the Linux host: ghostd signs you in, wraith streams the desktop.")
            step(2, "Make sure this device can reach it: the same network, or the same VPN, such as Tailscale.")
            step(3, "Add the server with +, then tap Connect and sign in with your account on it.")
        }
        .multilineTextAlignment(.leading)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "\(n).circle.fill").foregroundStyle(.tint)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
