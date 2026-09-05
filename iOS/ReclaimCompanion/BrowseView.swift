import ReclaimKit
import SwiftUI

/// A folder to open, as a navigation value.
struct BrowseTarget: Hashable {
    let path: String
}

/// One folder of one tab: the map above, the same data ranked below.
///
/// The Mac puts the list beside the map because a desktop window is wide. A
/// phone is tall, so they stack — and the divider between them is draggable for
/// the same reason it is on the Mac: which half matters depends on the folder.
struct BrowseView: View {
    @ObservedObject var session: MacSession
    let tab: CompanionAPI.TabSummary
    /// Nil is the tab's scan root.
    let path: String?

    @State private var node: CompanionAPI.Node?
    @State private var failure: String?
    @State private var selected: String?
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
        .navigationTitle(node?.name ?? tab.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.panel, for: .navigationBar)
        // Its own destination type, so this does not collide with the Mac list's
        // own `String` destination further up the same stack.
        .navigationDestination(item: $pushed) { target in
            BrowseView(session: session, tab: tab, path: target.path)
        }
        .task { await load() }
    }

    // MARK: - Layout

    private func content(_ node: CompanionAPI.Node) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
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
                        drill(child)
                    }
                    .frame(height: max(140, geometry.size.height * mapShare))
                    .padding(.horizontal, 12)

                    divider(over: geometry.size.height)

                    ChildList(node: node, selected: $selected, drill: drill)
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
        pushed = BrowseTarget(path: child.path)
    }

    private func load() async {
        failure = nil
        do {
            node = try await session.node(tab: tab.id, path: path)
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// The strip of numbers, in the Mac's own order: this folder, then what is in it.
private struct Summary: View {
    let node: CompanionAPI.Node

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            figure(node.human, "in view")
            figure(node.fileCount.formatted(.number), "files")
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
    let drill: (CompanionAPI.NodeChild) -> Void

    var body: some View {
        List {
            ForEach(node.children) { child in
                Row(child: child, isSelected: child.path == selected)
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
