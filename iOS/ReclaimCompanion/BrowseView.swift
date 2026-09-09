import ReclaimKit
import SwiftUI

/// A folder to open, as a navigation value.
struct BrowseTarget: Hashable {
    let path: String
    /// The name it was listed under. Carried so the screen it opens is titled
    /// the moment it appears, rather than after its contents have been fetched.
    let name: String
}

/// One folder of a scan: the map above, the same data ranked below.
///
/// The Mac puts the list beside the map because a desktop window is wide. A
/// phone is tall, so they stack — and the divider between them is draggable for
/// the same reason it is on the Mac: which half matters depends on the folder.
struct BrowseView: View {
    @ObservedObject var session: MacSession
    let source: BrowseSource
    /// Nil is the scan root.
    let path: String?
    /// What to call this folder before it has been fetched — the name the row
    /// that opened it already showed. Nil at the scan root, which the source names.
    let name: String?

    @State private var node: CompanionAPI.Node?
    @State private var failure: String?
    @State private var selected: String?
    /// Bumped by a map tap that stays on this screen, so the list brings the
    /// row it named into the middle.
    ///
    /// A count rather than a flag on the selection, because the gesture worth
    /// serving most is the second tap on the same tile: the reader has scrolled
    /// the list away, and taps that small file again to find it. The path has
    /// not changed, so nothing derived from it fires — but the tap did happen,
    /// and this counts taps.
    ///
    /// A tap on a row bumps nothing: that row is in view by definition, and
    /// scrolling the list out from under the finger that touched it is not
    /// synchronising anything.
    @State private var centreRequest = 0
    /// Fraction of the height the map takes. Kept per screen rather than
    /// remembered: a folder of two tiles and a folder of two hundred do not
    /// want the same split.
    @State private var mapShare: CGFloat = 0.42
    @State private var dragStart: CGFloat?
    /// The folder a tap asked for, which pushes the next screen.
    @State private var pushed: BrowseTarget?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let node {
                content(node)
            } else if let failure {
                Notice(icon: "questionmark.folder", title: "Cannot show that folder",
                       detail: failure, action: ("Try Again", { Task { await load() } }))
            } else {
                ProgressView().controlSize(.large)
            }
        }
        // The name comes from the row that was tapped, so the title is right on
        // the way in rather than after the fetch. The rule lives in ReclaimKit
        // because the scan root is a case of its own, and it is easier to state
        // once and test than to read out of a chain of `??`.
        .navigationTitle(CompanionAPI.folderTitle(path: path, fetched: node?.name,
                                                  row: name, tab: source.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.panel, for: .navigationBar)
        // Its own destination type, so this does not collide with the Mac list's
        // own `String` destination further up the same stack.
        .navigationDestination(item: $pushed) { target in
            BrowseView(session: session, source: source, path: target.path, name: target.name)
        }
        .task { await load() }
    }

    // MARK: - Layout

    private func content(_ node: CompanionAPI.Node) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let asOf = source.asOf {
                    Text("As of \(asOf.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                Summary(node: node)

                if node.children.isEmpty {
                    Notice(icon: "tray", title: "Nothing in here",
                           detail: node.isDirectory
                               ? "This folder is empty, or everything in it is too small to measure."
                               : "This is a file, not a folder.")
                        .frame(maxHeight: .infinity)
                } else {
                    TreemapCanvas(children: node.children, selected: selected,
                                  isResizing: dragStart != nil) { child in
                        selected = child.path
                        // A folder tile is on its way to another screen, and
                        // the list it would scroll is the one being replaced.
                        // A folder has a destination, not a row to find.
                        if !child.isDirectory { centreRequest += 1 }
                        drill(child)
                    }
                    .frame(height: max(140, geometry.size.height * mapShare))
                    .padding(.horizontal, 12)

                    divider(over: geometry.size.height)

                    ChildList(node: node, selected: $selected,
                              centreRequest: centreRequest, drill: drill)
                }

                Breadcrumb(node: node)
            }
        }
    }

    /// Drag to give the map or the list more room.
    private func divider(over height: CGFloat) -> some View {
        Capsule()
            .fill(Theme.hairline)
            .frame(width: 44, height: 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { drag in
                        let start = dragStart ?? mapShare
                        dragStart = start
                        // Against the height being divided, so the tile edge
                        // follows the finger rather than lagging it.
                        mapShare = min(0.75, max(0.15,
                                                 start + drag.translation.height / max(1, height)))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }

    // MARK: - Navigation

    /// A folder opens; a file is only ever selected, because there is nothing
    /// inside it to show.
    private func drill(_ child: CompanionAPI.NodeChild) {
        guard child.isDirectory else {
            selected = child.path
            return
        }
        pushed = BrowseTarget(path: child.path, name: child.name)
    }

    private func load() async {
        failure = nil
        do {
            node = try await source.node(from: session, path: path)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// Where a browse screen gets its tree: a live tab, or last night's snapshot.
enum BrowseSource {
    case tab(CompanionAPI.TabSummary)
    case watched(CompanionAPI.WatchedSummary)

    var title: String {
        switch self {
        case .tab(let tab): return tab.title
        case .watched(let watched): return watched.title
        }
    }

    /// Snapshot time, when this is not a live window.
    var asOf: Date? {
        switch self {
        case .tab: return nil
        case .watched(let watched): return watched.takenAt
        }
    }

    func node(from session: MacSession, path: String?) async throws -> CompanionAPI.Node {
        switch self {
        case .tab(let tab):
            return try await session.node(tab: tab.id, path: path)
        case .watched(let watched):
            return try await session.watchedNode(target: watched.target, path: path)
        }
    }
}

/// The strip of numbers, in the Mac's own order: this folder, then what is in it.
private struct Summary: View {
    let node: CompanionAPI.Node

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            figure(node.human, "in view")
            if node.fileCount > 0 {
                figure(node.fileCount.formatted(.number), "files")
            }
            figure((node.children.count + node.omittedChildren).formatted(.number),
                   "items here")
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The same data as the map, ranked — largest first, with a share bar.
private struct ChildList: View {
    let node: CompanionAPI.Node
    @Binding var selected: String?
    /// Counts the map taps that want a row brought into view. See `BrowseView`.
    let centreRequest: Int
    let drill: (CompanionAPI.NodeChild) -> Void

    var body: some View {
        ScrollViewReader { list in
            rows
                // The row a tile named is usually somewhere off the bottom of a
                // phone-sized list, and a selection nobody can see is not a
                // selection. Centred rather than merely scrolled into view, so
                // its neighbours — the tiles either side of it on the map —
                // come with it.
                //
                // Driven by the tap count, not by the selected path: tapping
                // the same tile twice is the same path, and it is exactly the
                // gesture that means "show me that again".
                .onChange(of: centreRequest) { _, _ in
                    guard let selected else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        list.scrollTo(selected, anchor: .center)
                    }
                }
        }
    }

    private var rows: some View {
        List {
            ForEach(node.children) { child in
                Row(child: child, isSelected: child.path == selected)
                    // The id `scrollTo` is given. `ForEach` over an
                    // `Identifiable` is not enough on its own: the proxy inside
                    // a `List` does not reliably see the element's own id, and
                    // a `scrollTo` it cannot resolve is silently nothing.
                    .id(child.path)
                    .listRowBackground(child.path == selected ? Theme.raised : Theme.panel)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selected = child.path
                        drill(child)
                    }
            }
            if node.omittedChildren > 0 {
                Text("and \(node.omittedChildren) smaller items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Theme.panel)
            }
            if !node.types.isEmpty {
                Section("By type") {
                    ForEach(node.types) { total in
                        HStack {
                            Circle().fill(total.family.color).frame(width: 9, height: 9)
                            Text(total.family.label)
                            Spacer()
                            Text(total.human)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .listRowBackground(Theme.panel)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private struct Row: View {
        let child: CompanionAPI.NodeChild
        let isSelected: Bool

        var body: some View {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(child.family.color)
                    .frame(width: 4, height: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(child.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.hairline)
                            Capsule()
                                .fill(child.family.color.opacity(0.8))
                                .frame(width: max(2, geometry.size.width * child.share))
                        }
                    }
                    .frame(height: 3)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(child.human).font(.subheadline.monospacedDigit())
                    Text("\(Int((child.share * 100).rounded()))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if child.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Where in the scan this folder sits. Not a control: the way back is Back,
/// and two ways up an identical hierarchy is one too many.
private struct Breadcrumb: View {
    let node: CompanionAPI.Node

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(node.breadcrumb.enumerated()), id: \.element.id) { index, crumb in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(crumb.name == "/" ? "Disk" : crumb.name)
                        .font(.caption)
                        .foregroundStyle(index == node.breadcrumb.count - 1
                                         ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(Theme.panel)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Theme.hairline),
                 alignment: .top)
    }
}
