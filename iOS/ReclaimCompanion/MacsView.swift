import ReclaimKit
import SwiftUI

/// The Macs on this network, which is where the app starts.
struct MacsView: View {
    @StateObject private var discovery = Discovery()
    @State private var refreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Reclaim")
            // Inline: a large title spent the top third of the screen saying
            // the name of the app somebody has just opened, above a list that
            // is usually one row long.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.panel, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await discovery.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refreshing)
                }
            }
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = discovery.failure {
            // Every dead end has a way out of it: looking again is the whole
            // of what this screen does, and a browser that has given up can
            // only be replaced, never revived.
            Notice(icon: "wifi.exclamationmark", title: "Cannot look for Macs",
                   detail: failure,
                   action: ("Try Again", { refresh() }))
        } else if discovery.macs.isEmpty {
            Notice(icon: "magnifyingglass",
                   title: discovery.isSearching ? "Looking for your Mac" : "No Macs found",
                   detail: "Open Reclaim on your Mac and turn on "
                       + "Settings → Companion → Answer on this network. "
                       + "Both devices have to be on the same Wi-Fi.",
                   busy: discovery.isSearching && !refreshing,
                   action: ("Look Again", { refresh() }))
        } else {
            List(discovery.macs) { mac in
                NavigationLink(value: mac.id) {
                    // The Mac's name and nothing else: every row in this list is
                    // a Mac running Reclaim, so saying so on each of them says
                    // nothing.
                    Label {
                        Text(mac.name).font(.headline)
                    } icon: {
                        Image(systemName: "desktopcomputer").foregroundStyle(Theme.ember)
                    }
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
            .refreshable { await discovery.refresh() }
            .navigationDestination(for: String.self) { id in
                // Looked up rather than carried, so a Mac that vanishes from the
                // network cannot leave a screen pointing at nothing.
                if let mac = discovery.macs.first(where: { $0.id == id }) {
                    MacView(mac: mac)
                } else {
                    Notice(icon: "bolt.horizontal.circle",
                           title: "That Mac has gone",
                           detail: "It left the network. It will come back on its own "
                               + "when Reclaim is running again.")
                }
            }
        }
    }
}

private extension MacsView {
    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        Task {
            await discovery.refresh()
            refreshing = false
        }
    }
}

/// The full-screen way this app says something is missing, wrong, or pending.
struct Notice: View {
    let icon: String
    let title: String
    var detail: String?
    var busy = false
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            if busy {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.ember)
            }
            Text(title).font(.headline)
            if let detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
    }
}
