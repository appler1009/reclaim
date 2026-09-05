import ReclaimKit
import SwiftUI

/// The Macs on this network, which is where the app starts.
struct MacsView: View {
    @StateObject private var discovery = Discovery()

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                content
            }
            .navigationTitle("Reclaim")
            .toolbarBackground(Theme.panel, for: .navigationBar)
        }
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = discovery.failure {
            Notice(icon: "wifi.exclamationmark", title: "Cannot look for Macs", detail: failure)
        } else if discovery.macs.isEmpty {
            Notice(icon: "magnifyingglass",
                   title: "Looking for your Mac",
                   detail: "Open Reclaim on your Mac and turn on "
                       + "Settings → Companion → Answer on this network. "
                       + "Both devices have to be on the same Wi-Fi.",
                   busy: true)
        } else {
            List(discovery.macs) { mac in
                NavigationLink(value: mac.id) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.name).font(.headline)
                            Text("Reclaim").font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "desktopcomputer").foregroundStyle(Theme.ember)
                    }
                }
                .listRowBackground(Theme.panel)
            }
            .scrollContentBackground(.hidden)
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
