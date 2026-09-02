import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var confirming = false
    @State private var report: AppModel.DeleteReport?
    @State private var working = false
    @AppStorage(SidebarWidth.storageKey) private var sidebarWidth = SidebarWidth.default

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar(model: model)
                Divider().overlay(Color.hairline)
                HStack(spacing: 0) {
                    MapPane(model: model)
                    PaneDivider(width: $sidebarWidth)
                    BreakdownPane(model: model,
                                  working: working,
                                  onTrash: { confirming = true })
                        .frame(width: SidebarWidth.clamped(sidebarWidth))
                }
            }
            if model.phase != .ready { Overlay(model: model) }
        }
        // An ideal size matters as much as the minimum: the content is greedy in
        // both axes, and without one SwiftUI grows the window to fill the display.
        .frame(minWidth: 1080, idealWidth: 1320, minHeight: 680, idealHeight: 860)
        .onAppear { model.scanLaunchArgumentIfPresent() }
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.phase == .ready {
                    Menu {
                        ForEach(SizeMeasure.allCases, id: \.self) { measure in
                            Button {
                                model.measure = measure
                                model.refreshBreakdown()
                            } label: {
                                if model.measure == measure {
                                    Label(measure.label, systemImage: "checkmark")
                                } else {
                                    Text(measure.label)
                                }
                            }
                        }
                    } label: {
                        Label(model.measure.label, systemImage: "ruler")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Which size to report: bytes occupied on disk, or the files' logical length")

                    Button { model.rescan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Scan this location again")
                }
                ScanMenu(model: model)
            }
        }
        // Toolbar items default to icon-only; these read better with their words.
        .toolbarTitleDisplayMode(.inline)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("Moved \(ByteFormat.string(report?.bytes ?? 0)) to the Trash",
               isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("Done") { report = nil }
        } message: {
            if let report {
                Text(report.failures.isEmpty
                     ? "\(report.trashed.count) item\(report.trashed.count == 1 ? "" : "s") moved to the Trash. Empty the Trash to free the space for good."
                     : "\(report.trashed.count) moved to the Trash. \(report.failures.count) could not be removed:\n"
                       + report.failures.prefix(3).map { "· \($0.name): \($0.reason)" }.joined(separator: "\n"))
            }
        }
    }

    private var confirmTitle: String {
        "Move \(model.staged.count) item\(model.staged.count == 1 ? "" : "s") to the Trash?"
    }

    private var confirmMessage: String {
        let items = model.staged
        let preview = items.prefix(6)
            .map { "· \($0.path)  (\(ByteFormat.string($0.size(model.measure))))" }
            .joined(separator: "\n")
        let more = items.count > 6 ? "\n· and \(items.count - 6) more…" : ""
        return "This frees \(ByteFormat.string(model.stagedBytes)) once the Trash is emptied. "
             + "Nothing is deleted permanently.\n\n" + preview + more
    }

    private func performTrash() {
        working = true
        Task {
            let result = await model.trashStaged()
            working = false
            report = result
        }
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "square.grid.3x3.topleft.filled")
                    .foregroundStyle(Color.ember)
                    .font(.system(size: 15, weight: .bold))
                Text("RECLAIM")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(2.6)
                    .foregroundStyle(.white.opacity(0.9))
            }

            if model.phase == .ready || model.phase == .scanning {
                Divider().frame(height: 26).overlay(Color.hairline)

                // The one place sizes are reported: always the folder in view.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormat.string(model.viewedBytes))
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.22), value: model.viewedBytes)
                        if model.zoomRoot !== model.scanRoot, model.scannedBytes > 0 {
                            Text("· \(Int((Double(model.viewedBytes) / Double(model.scannedBytes) * 100).rounded()))% of scan")
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                        }
                    }
                    Overline(text: model.zoomRoot === model.scanRoot
                             ? "Total \(model.measure == .physical ? "on disk" : "size")"
                             : "This folder")
                }
                .help("Everything inside \(model.zoomRoot?.name ?? "this folder"), added up. "
                      + "The toolbar chooses between space occupied on disk and the files' own size.")

                Metric(value: model.breakdown.files.formatted(), caption: "Files inside")
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: model.breakdown.files)
                    .help("Files anywhere below this folder, however deeply nested. Folders are not counted.")
                Metric(value: model.breakdown.rows.count.formatted(), caption: "Items here")
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: model.breakdown.rows.count)
                    .help("Folders and files directly inside this one — the tiles on the map and the rows in the list.")
                // Everything to the left describes the folder in view; what
                // follows describes the whole volume, so it is set apart.
                if model.volumeCapacity > 0 || (model.scanRoot?.unreadableCount ?? 0) > 0 {
                    Divider().frame(height: 26).overlay(Color.hairline)
                }
                if model.volumeCapacity > 0 {
                    Metric(value: ByteFormat.string(model.volumeFree), caption: "Free on volume")
                        .help("Space still available on the whole disk this scan came from — not part of the totals to the left.")
                }
                if let unreadable = model.scanRoot?.unreadableCount, unreadable > 0 {
                    Button { model.openFullDiskAccessSettings() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.caution)
                            Metric(value: unreadable.formatted(),
                                   caption: "Unreadable",
                                   tint: Color.caution)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(unreadable) directories could not be read, so their space is uncounted. Grant Full Disk Access to include them.")
                }
            }

            Spacer()
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Color.panel)
    }
}

// MARK: - Map pane

private struct MapPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.zoomOut() } label: {
                    Label("Up", systemImage: "arrow.up.left")
                }
                .buttonStyle(GhostButtonStyle())
                .disabled(model.zoomRoot === model.scanRoot)
                .help("Go to the enclosing folder (⌘↑)")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            Button { model.show(node) } label: {
                                Text(index == 0 ? node.name : node.name)
                                    .font(.system(size: 11, weight: index == model.breadcrumb.count - 1 ? .semibold : .regular))
                                    .foregroundStyle(.white.opacity(index == model.breadcrumb.count - 1 ? 0.92 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Spacer(minLength: 8)
                LegendStrip()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.panel.opacity(0.6))
            .animation(.snappy(duration: 0.2), value: model.zoomRoot?.objectID)

            TreemapRepresentable(model: model)
                .background(Color.ink)
                .clipped()

            HoverBar(model: model, hover: model.hover)
        }
        .onReceive(NotificationCenter.default.publisher(for: .reclaimNavigateUp)) { _ in
            model.zoomOut()
        }
    }
}

private struct LegendStrip: View {
    private let families: [FileFamily] = [.code, .media, .image, .archive,
                                          .document, .app, .data, .system, .other]

    var body: some View {
        HStack(spacing: 9) {
            ForEach(families, id: \.self) { family in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: family.color))
                        .frame(width: 8, height: 8)
                    Text(family.label)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

private struct HoverBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var hover: HoverState

    var body: some View {
        let item = hover.item ?? model.selectedItem
        HStack(spacing: 12) {
            if let item {
                Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(Color(nsColor: FileFamily.of(item).color))
                    .font(.system(size: 11))
                Text(item.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if item.isDirectory {
                    Text("\(item.fileCount.formatted()) files")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                }
                Text(ByteFormat.string(item.size(model.measure)))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.92))
                Button { model.revealInFinder(item) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.5))
                    .help("Reveal in Finder")
            } else {
                Text("Hover to inspect · double-click or scroll down to go into a folder · scroll up to go back")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.32))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.panel.opacity(0.6))
    }
}

// MARK: - Breakdown pane

private struct BreakdownPane: View {
    @ObservedObject var model: AppModel
    var working: Bool
    var onTrash: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !model.breakdown.rows.isEmpty {
                        PaneSection(title: "Contents, largest first") {
                            // Lazy: a folder with dozens of children rebuilt every
                            // row on every navigation, and SwiftUI's view graph
                            // was the whole of the main thread in a profile.
                            LazyVStack(spacing: 2) {
                                if let parent = model.zoomRoot?.parent,
                                   model.zoomRoot !== model.scanRoot {
                                    UpRow(parentName: parent.name) { model.zoomOut() }
                                }
                                ForEach(model.breakdown.rows.prefix(40)) { row in
                                    BreakdownRowView(
                                        row: row,
                                        measure: model.measure,
                                        isStaged: model.isStaged(row.node),
                                        isSelected: model.selectedItem === row.node,
                                        onToggleStaged: { model.toggleStaged(row.node) },
                                        onShow: { model.show(row.node) },
                                        onOpen: { model.zoom(into: row.node) },
                                        onReveal: { model.revealInFinder(row.node) })
                                    .equatable()
                                }
                                if model.breakdown.rows.count > 40 {
                                    Text("+ \(model.breakdown.rows.count - 40) smaller items")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.white.opacity(0.35))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 5)
                                }
                            }
                        }
                    }
                    if !model.breakdown.types.isEmpty {
                        PaneSection(title: "By file type") {
                            LazyVStack(spacing: 3) {
                                ForEach(model.breakdown.types) { total in
                                    TypeRowView(total: total, of: model.breakdown.total)
                                }
                            }
                        }
                    }
                }
                .padding(12)
                // Keyed on the folder so the list moves as one, in the same
                // direction the map zooms. Measured free next to the SwiftUI
                // pass it rides along with.
                .transition(.asymmetric(
                    insertion: .move(edge: model.navigatedInwards ? .bottom : .top)
                        .combined(with: .opacity),
                    removal: .opacity))
                .id(model.zoomRoot?.objectID)
            }
            .animation(.snappy(duration: 0.2), value: model.zoomRoot?.objectID)

            Divider().overlay(Color.hairline)
            TrashTray(model: model, working: working, onTrash: onTrash)
        }
        .background(Color.panel)
    }
}

private struct PaneSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline(text: title)
            content
        }
    }
}

/// A row in the contents list.
///
/// Takes plain values rather than observing the model: as an observer, every
/// row re-evaluated on any model change at all — hovering a tile invalidated the
/// whole sidebar. `Equatable` lets SwiftUI skip rows whose inputs did not move.
private struct BreakdownRowView: View, Equatable {
    let row: BreakdownRow
    let measure: SizeMeasure
    let isStaged: Bool
    let isSelected: Bool
    let onToggleStaged: () -> Void
    let onShow: () -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void

    @State private var hovering = false

    static func == (lhs: BreakdownRowView, rhs: BreakdownRowView) -> Bool {
        lhs.row.id == rhs.row.id
            && lhs.row.bytes == rhs.row.bytes
            && lhs.measure == rhs.measure
            && lhs.isStaged == rhs.isStaged
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 8) {
            CheckBox(state: isStaged, action: onToggleStaged)

            Image(systemName: row.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: row.node.dominantFamily(measure).color).opacity(0.9))
                .frame(width: 13)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1).truncationMode(.middle)
                // A Shape rather than a GeometryReader: it is handed the row's
                // real width at draw time, so the bar follows the sidebar as it
                // is resized without a reader per row slowing list rebuilds.
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.06))
                    ShareBar(share: row.share)
                        .fill(Color(nsColor: row.node.dominantFamily(measure).color).opacity(0.75))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 3)
            }

            Text(ByteFormat.string(row.bytes))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 62, alignment: .trailing)
            Text("\(Int(row.share * 100))%")
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 30, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering || isSelected ? Color.white.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onShow)
        .contextMenu {
            if row.isDirectory { Button("Open in map", action: onOpen) }
            Button("Reveal in Finder", action: onReveal)
            Button(isStaged ? "Remove from selection" : "Select for Trash", action: onToggleStaged)
        }
        .help(row.node.path)
    }
}

private struct TypeRowView: View {
    let total: TypeTotal
    let of: UInt64

    private var share: Double { of > 0 ? Double(total.bytes) / Double(of) : 0 }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(nsColor: total.family.color))
                .frame(width: 9, height: 9)
            Text(total.family.label)
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 6)
            Text("\(total.files.formatted()) files")
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.32))
            Text(ByteFormat.string(total.bytes))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 62, alignment: .trailing)
            Text("\(Int(share * 100))%")
                .font(.system(size: 10)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.35))
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct TrashTray: View {
    @ObservedObject var model: AppModel
    var working: Bool
    var onTrash: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(model.staged.isEmpty
                     ? "Select anything to remove it"
                     : "\(model.staged.count) selected · \(ByteFormat.string(model.stagedBytes))")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !model.staged.isEmpty {
                    Button("Clear") { model.clearStaging() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
                }
            }
            if !model.staged.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(model.staged.prefix(4)), id: \.objectID) { node in
                        HStack(spacing: 6) {
                            Text(node.name)
                                .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(ByteFormat.string(node.size(model.measure)))
                                .font(.system(size: 10)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.5))
                            Button { model.toggleStaged(node) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.35))
                        }
                    }
                    if model.staged.count > 4 {
                        Text("+ \(model.staged.count - 4) more")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            Button(action: onTrash) {
                HStack(spacing: 7) {
                    if working { ProgressView().controlSize(.small) }
                    Image(systemName: "trash.fill")
                    Text(model.stagedBytes > 0
                         ? "Move \(ByteFormat.string(model.stagedBytes)) to Trash"
                         : "Move to Trash")
                }
            }
            .buttonStyle(PrimaryButtonStyle(enabled: !model.staged.isEmpty && !working))
            .disabled(model.staged.isEmpty || working)

            Text("Items go to the Trash — you can put them back.")
                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.33))
        }
        .padding(12)
    }
}

// MARK: - Overlays

private struct Overlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color.ink.opacity(model.phase == .scanning ? 0.86 : 1).ignoresSafeArea()
            switch model.phase {
            case .idle:
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    VStack(spacing: 18) {
                        VStack(spacing: 10) {
                            Image(systemName: "square.grid.3x3.topleft.filled")
                                .font(.system(size: 42)).foregroundStyle(Color.ember)
                            Text("See where your disk space went")
                                .font(.system(size: 22, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                            Text("Pick a disk or a folder. Every file becomes a tile sized by the\nspace it uses, so you can see where it all went.")
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 34)

                        VolumeGrid(model: model)

                        if !model.hasFullDiskAccess {
                            FullDiskAccessNote(model: model)
                        }

                        HStack(spacing: 10) {
                            Button { model.scan(FileManager.default.homeDirectoryForCurrentUser) } label: {
                                Label("Scan Home folder", systemImage: "house.fill")
                            }
                            .buttonStyle(GhostButtonStyle())
                            Button { model.chooseFolder() } label: {
                                Label("Choose a folder…", systemImage: "folder")
                            }
                            .buttonStyle(GhostButtonStyle())
                        }
                        .padding(.bottom, 30)
                    }
                    .frame(maxWidth: 780)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Scanning \(model.scannedURL?.lastPathComponent ?? "")")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    Text("\(model.progress.filesScanned.formatted()) files · \(ByteFormat.string(model.progress.bytesScanned))")
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(.white.opacity(0.6))
                    Text(model.progress.currentPath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
                    Button("Cancel") { model.cancelScan() }
                        .buttonStyle(GhostButtonStyle())
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 30)).foregroundStyle(.orange)
                    Text(message).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                    Button("Choose another folder…") { model.chooseFolder() }
                        .buttonStyle(GhostButtonStyle())
                }
            case .ready:
                EmptyView()
            }
        }
    }
}

// MARK: - Volume selection

struct ScanMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Section("Volumes") {
                ForEach(model.volumes) { volume in
                    Button {
                        model.scan(volume: volume)
                    } label: {
                        Text("\(volume.name) — \(ByteFormat.string(volume.available)) free")
                    }
                }
            }
            Divider()
            Button("Home folder") { model.scan(FileManager.default.homeDirectoryForCurrentUser) }
            Button("Choose a folder…") { model.chooseFolder() }
            Divider()
            Button("Refresh volumes") { model.refreshVolumes() }
        } label: {
            Label("Scan", systemImage: "internaldrive")
        }
        .labelStyle(.titleAndIcon)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(Color.ember)
    }
}

private struct VolumeGrid: View {
    @ObservedObject var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 236, maximum: 340), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Overline(text: "Volumes")
                Spacer()
                Button { model.refreshVolumes() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.4))
                .help("Refresh the list of mounted volumes")
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(model.volumes) { volume in
                    VolumeCard(volume: volume) { model.scan(volume: volume) }
                }
            }
            if model.volumes.isEmpty {
                Text("No mounted volumes found.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 24)
    }
}

private struct VolumeCard: View {
    let volume: VolumeInfo
    let action: () -> Void
    @State private var hovering = false

    /// Fill turns hot as the disk fills up — the card doubles as a gauge.
    private var barColor: Color {
        switch volume.usedFraction {
        case ..<0.75: return Color(nsColor: FileFamily.image.color)
        case ..<0.90: return Color.caution
        default: return Color.ember
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 9) {
                    Image(nsImage: volume.icon)
                        .resizable().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(volume.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                        Text(volume.kindDescription + (volume.isReadOnly ? " · read-only" : ""))
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(hovering ? Color.ember : .white.opacity(0.18))
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.07))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [barColor.opacity(0.85), barColor],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, geometry.size.width * volume.usedFraction))
                    }
                }
                .frame(height: 6)

                HStack(spacing: 4) {
                    Text(ByteFormat.string(volume.used))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))
                    Text("used of \(ByteFormat.string(volume.capacity))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                    Spacer()
                    Text("\(ByteFormat.string(volume.available)) free")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(barColor.opacity(0.9))
                }
            }
            .padding(13)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(hovering ? Color.ember.opacity(0.55) : Color.white.opacity(0.09), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Scan \(volume.url.path)")
    }
}

private struct FullDiskAccessNote: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.caution)
            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Full Disk Access for a complete scan")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                Text("Without it macOS hides other users' data and some system folders, and those bytes go uncounted.")
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            Button("Open Settings…") { model.openFullDiskAccessSettings() }
                .buttonStyle(GhostButtonStyle())
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.caution.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.caution.opacity(0.25), lineWidth: 1)
        )
        .padding(.horizontal, 24)
    }
}


private struct CheckBox: View {
    /// true = on, false = off, nil = mixed.
    let state: Bool?
    let action: () -> Void

    init(state: Bool?, action: @escaping () -> Void) { self.state = state; self.action = action }

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(state == false ? Color.white.opacity(0.06) : Color.ember)
                .frame(width: 14, height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(state == false ? 0.18 : 0), lineWidth: 1)
                )
                .overlay(
                    Group {
                        if state == true {
                            Image(systemName: "checkmark").font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.black.opacity(0.8))
                        } else if state == nil {
                            Rectangle().fill(.black.opacity(0.75)).frame(width: 7, height: 2)
                        }
                    }
                )
        }
        .buttonStyle(.plain)
    }
}

/// "…" row that walks back up to the enclosing folder, so the list navigates
/// both ways without reaching for the toolbar.
private struct UpRow: View {
    let parentName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.ember)
                    .frame(width: 27, alignment: .trailing)
                Text(parentName.isEmpty ? "Enclosing folder" : parentName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("up")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}


/// The filled portion of a row's share bar, sized from the width it is given.
private struct ShareBar: Shape {
    let share: Double

    func path(in rect: CGRect) -> Path {
        let width = max(2, rect.width * share)
        return Path(roundedRect: CGRect(x: rect.minX, y: rect.minY,
                                        width: width, height: rect.height),
                    cornerRadius: 2)
    }
}
