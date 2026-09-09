import ReclaimKit
import SwiftUI

/// What this Mac can show: open tabs, and watched folders that have no tab.
struct TabsView: View {
    @ObservedObject var session: MacSession

    private var isEmpty: Bool { session.tabs.isEmpty && session.watched.isEmpty }

    var body: some View {
        Group {
            if isEmpty {
                Notice(icon: "macwindow",
                       title: "Nothing to browse",
                       detail: "Scan a disk or a folder on your Mac, or add one to the "
                         + "overnight watchlist, and it will appear here.",
                       action: ("Refresh", { Task { await session.refresh() } }))
            } else {
                List {
                    if let warning = session.warning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(Theme.caution)
                            .listRowBackground(Theme.panel)
                    }
                    if !session.tabs.isEmpty {
                        Section("Open tabs") {
                            ForEach(session.tabs) { tab in
                                NavigationLink {
                                    BrowseView(session: session, source: .tab(tab),
                                               path: nil, name: nil)
                                } label: {
                                    TabRow(tab: tab)
                                }
                                .listRowBackground(Theme.panel)
                                // A tab that has nothing to show yet is a heading, not
                                // a destination.
                                .disabled(tab.totalBytes == 0 && !tab.isScanning)
                            }
                        }
                    }
                    if !session.watched.isEmpty {
                        Section {
                            ForEach(session.watched) { watched in
                                NavigationLink {
                                    BrowseView(session: session, source: .watched(watched),
                                               path: nil, name: nil)
                                } label: {
                                    WatchedRow(watched: watched)
                                }
                                .listRowBackground(Theme.panel)
                                .disabled(watched.takenAt == nil)
                            }
                        } header: {
                            Text("Watched overnight")
                        } footer: {
                            Text("Last recorded scan, not a live window. Small folders "
                                 + "deep in the tree may be missing.")
                        }
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
        // Tabs and the watchlist change on the Mac while the phone is looking
        // at them, so the list is re-read on return.
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

private struct WatchedRow: View {
    let watched: CompanionAPI.WatchedSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(watched.title).font(.headline)
                Spacer()
                Text(watched.takenAt == nil ? "—" : watched.totalHuman)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(watched.takenAt == nil ? .secondary : .primary)
            }
            Text(watched.target.abbreviatingMacHome)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let takenAt = watched.takenAt {
                Text("As of \(takenAt.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not scanned yet")
                    .font(.caption2)
                    .foregroundStyle(Theme.caution)
            }
        }
        .padding(.vertical, 3)
    }
}
