import ReclaimKit
import SwiftUI

/// The Mac's open tabs. A tab is a scan, which is why this list is short.
struct TabsView: View {
    @ObservedObject var session: MacSession

    var body: some View {
        Group {
            if session.tabs.isEmpty {
                Notice(icon: "macwindow",
                       title: "No scans open",
                       detail: "Scan a disk or a folder on your Mac and it will appear here.",
                       action: ("Refresh", { Task { await session.refresh() } }))
            } else {
                List {
                    if let warning = session.warning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(Theme.caution)
                            .listRowBackground(Theme.panel)
                    }
                    ForEach(session.tabs) { tab in
                        NavigationLink {
                            BrowseView(session: session, tab: tab, path: nil)
                        } label: {
                            TabRow(tab: tab)
                        }
                        .listRowBackground(Theme.panel)
                        // A tab that has nothing to show yet is a heading, not
                        // a destination.
                        .disabled(tab.totalBytes == 0 && !tab.isScanning)
                    }
                }
                .scrollContentBackground(.hidden)
                .refreshable { await session.refresh() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Refresh") { Task { await session.refresh() } }
                    Button("Forget This Mac", role: .destructive) { session.unpair() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Tabs change on the Mac while the phone is looking at them — a scan
        // finishes, a window is closed — so the list is re-read on return.
        .task { await session.refresh() }
    }
}

private struct TabRow: View {
    let tab: CompanionAPI.TabSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(tab.title).font(.headline)
                Spacer()
                Text(tab.totalHuman)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(tab.totalBytes > 0 ? .primary : .secondary)
            }
            Text(tab.target.abbreviatingMacHome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if tab.isScanning {
                ProgressView(value: tab.progress ?? 0)
                    .tint(Theme.ember)
                Text("Scanning…").font(.caption2).foregroundStyle(Theme.ember)
            } else if let error = tab.error {
                Text(error).font(.caption2).foregroundStyle(Theme.caution)
            } else if let volume = tab.volume {
                Text("\(volume.freeHuman) free on \(volume.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
