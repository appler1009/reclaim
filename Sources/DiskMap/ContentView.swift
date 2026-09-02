import QuartzCore
import SwiftUI

struct ContentView: View {
    /// One model per window: each window is an independent scan, which is what
    /// makes a second tab worth opening.
    @StateObject private var model = AppModel()
    @State private var report: AppModel.DeleteReport?
    @State private var working = false
    @AppStorage(SidebarWidth.storageKey) private var storedSidebarWidth = SidebarWidth.default
    /// Live width while dragging. Writing straight to @AppStorage on every drag
    /// event round-tripped through UserDefaults and re-evaluated the whole view
    /// on each mouse move, which is what made the map stutter.
    @State private var draggingSidebarWidth: Double?

    private var sidebarWidth: Double {
        SidebarWidth.clamped(draggingSidebarWidth ?? storedSidebarWidth)
    }

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar(model: model)
                ScanProgressBar(model: model)
                Divider().overlay(Color.hairline)
                HStack(spacing: 0) {
                    MapPane(model: model, isResizing: draggingSidebarWidth != nil)
                    PaneDivider(
                        width: sidebarWidth,
                        onChange: { draggingSidebarWidth = $0 },
                        onEnd: {
                            storedSidebarWidth = sidebarWidth
                            draggingSidebarWidth = nil
                        })
                    BreakdownPane(model: model,
                                  working: working,
                                  onTrash: { performTrash() })
                        .frame(width: sidebarWidth)
                }
            }
            if model.phase != .ready { Overlay(model: model) }
        }
        // An ideal size matters as much as the minimum: the content is greedy in
        // both axes, and without one SwiftUI grows the window to fill the display.
        .frame(minWidth: 1080, idealWidth: 1320, minHeight: 680, idealHeight: 860)
        .onAppear {
            model.scanLaunchArgumentIfPresent()
            startResizeStressIfRequested()
        }
        // The title bar names what is open, not the app — the app's own name is
        // already on screen in the header, and repeating it says nothing. This
        // also makes the window identifiable in Mission Control and the window
        // menu when several scans are open.
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        // Points the menu bar at this window while it is in front.
        .focusedSceneValue(\.scan, model)
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    hierarchyMenu
                } label: {
                    Label("Up", systemImage: "arrow.up.left")
                } primaryAction: {
                    model.zoomOut()
                }
                .disabled(model.zoomRoot == nil || model.zoomRoot === model.scanRoot)
                .help("Go to the enclosing folder (⌘↑). Hold for the folders above it.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                // macOS sizes a toolbar pill to hug its label; at the default
                // control size that leaves the text almost touching the edges.
                if model.isScanning {
                    Button { model.cancelScan() } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 7)
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Stop scanning and keep what has been found so far")
                }
                if model.phase == .ready && !model.isScanning {
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
                            .padding(.horizontal, 7)
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Which size to report: bytes occupied on disk, or the files' logical length")

                    Button { model.rescan() } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                            .padding(.horizontal, 7)
                    }
                    .labelStyle(.titleAndIcon)
                    .help("Scan this location again")
                }
                ScanMenu(model: model)
            }
        }
        // Toolbar items default to icon-only; these read better with their words.
        .toolbarTitleDisplayMode(.inline)
        .alert("Some items could not be moved to the Trash",
               isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("Done") { report = nil }
        } message: {
            if let report {
                Text("\(report.trashed.count) moved, \(report.failures.count) could not be:\n"
                     + report.failures.prefix(4)
                        .map { "· \($0.name): \($0.reason)" }
                        .joined(separator: "\n"))
            }
        }
    }

    /// `--stress-resize` sweeps the divider through the same state path a real
    /// drag uses, and times the resulting update, so resizing can be measured
    /// rather than eyeballed.
    private func startResizeStressIfRequested() {
        guard CommandLine.arguments.contains("--stress-resize") else { return }
        var tick = 0
        var costs: [Double] = []
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                tick += 1
                let sweep = sin(Double(tick) / 18.0)          // back and forth
                let started = DispatchTime.now().uptimeNanoseconds
                draggingSidebarWidth = 520 + sweep * 200
                CATransaction.flush()
                NSApp.windows.first(where: { $0.isVisible })?.contentView?.displayIfNeeded()
                costs.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)

                if tick >= 240 {
                    timer.invalidate()
                    draggingSidebarWidth = nil
                    let sorted = costs.sorted()
                    Log.info("resize stress finished", [
                        "updates": "\(sorted.count)",
                        "medianMs": String(format: "%.2f", sorted[sorted.count / 2]),
                        "p95Ms": String(format: "%.2f", sorted[Int(Double(sorted.count - 1) * 0.95)]),
                        "maxMs": String(format: "%.2f", sorted.last ?? 0),
                        "over16ms": "\(sorted.filter { $0 > 16 }.count)",
                    ])
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Every folder between here and the scan root, nearest first.
    ///
    /// It stops at the scan root deliberately: that is the universe this scan
    /// measured, and nothing above it has numbers to show. Choosing a different
    /// target is what the Scan menu is for.
    @ViewBuilder
    private var hierarchyMenu: some View {
        let ancestors = Array(model.breadcrumb.dropLast().reversed())
        ForEach(Array(ancestors.enumerated()), id: \.offset) { index, node in
            Button {
                model.show(node)
            } label: {
                Label(node === model.scanRoot ? model.scanTargetName : node.name,
                      systemImage: index == ancestors.count - 1 ? "externaldrive" : "folder")
            }
        }
    }

    /// The title bar names what is open; the breadcrumb below handles navigation
    /// within it, so the two do not repeat each other.
    private var windowTitle: String {
        model.scanRoot == nil ? "Reclaim" : model.scanTargetName
    }

    /// The absolute path of the folder in view — the one place it is spelled out
    /// in full, which is why the breadcrumb can stay short.
    private var windowSubtitle: String {
        model.zoomRoot?.path ?? ""
    }

    private func performTrash() {
        working = true
        Task {
            let result = await model.trashStaged()
            working = false
            // Success needs no interruption: the tray and the header's trash
            // figure both say what happened. Failures still need attention.
            if !result.failures.isEmpty { report = result }
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
                    // No file count here: "files inside" sits right beside it.
                    Overline(text: model.isScanning
                             ? (model.scanCompletion.total > 0
                                ? "Scanning · \(model.scanCompletion.done) of \(model.scanCompletion.total) folders"
                                : "Scanning…")
                             : (model.zoomRoot === model.scanRoot
                                ? "Total \(model.measure == .physical ? "on disk" : "size")"
                                : "This folder"))
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
                if model.volumeCapacity > 0 {
                    Divider().frame(height: 26).overlay(Color.hairline)
                }
                if model.volumeCapacity > 0 {
                    Metric(value: ByteFormat.string(model.volumeFree), caption: "Free on volume")
                        .help("Space still available on the whole disk this scan came from — not part of the totals to the left.")
                }
                if model.trash.items > 0 {
                    // Its own group: this is neither the folder in view nor free
                    // space, but bytes waiting to become free.
                    Divider().frame(height: 26).overlay(Color.hairline)
                    Button { model.revealTrashInFinder() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.ember.opacity(0.9))
                            Metric(value: ByteFormat.string(model.trash.bytes),
                                   caption: "In trash",
                                   tint: Color.ember.opacity(0.95))
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.22), value: model.trash.bytes)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(trashHelp)
                }
                if let unreadable = model.scanRoot?.unreadableCount, unreadable > 0 {
                    // Not a measurement of anything: a caveat about the scan
                    // itself, and the one figure here that asks to be acted on.
                    Divider().frame(height: 26).overlay(Color.hairline)
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

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        .background(Color.panel)
    }

    private var trashHelp: String {
        let base = "\(model.trash.items) item\(model.trash.items == 1 ? "" : "s") in this volume's Trash, "
            + "holding \(ByteFormat.string(model.trash.bytes)). "
            + "That space comes back when the Trash is emptied."
        guard model.trashedThisSession > 0 else { return base + " Click to open it in Finder." }
        return base + " \(ByteFormat.string(model.trashedThisSession)) of it was moved here in this session."
            + " Click to open it in Finder."
    }
}

// MARK: - Map pane

private struct MapPane: View {
    @ObservedObject var model: AppModel
    var isResizing = false

    var body: some View {
        VStack(spacing: 0) {
            TreemapRepresentable(model: model, isResizing: isResizing)
                .background(Color.ink)
                .clipped()

            HoverBar(model: model, hover: model.hover)
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
            // The contents list needs no heading: it is the pane, and every row
            // is self-describing.
            ScrollView {
                // Lazy: a folder with dozens of children rebuilt every row on
                // every navigation, and SwiftUI's view graph was the whole of the
                // main thread in a profile.
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

            // Outside the scroll view: the type summary describes the whole
            // folder, so it should not scroll away with the list it summarises.
            if !model.breakdown.types.isEmpty {
                Divider().overlay(Color.hairline)
                VStack(spacing: 3) {
                    ForEach(model.breakdown.types) { total in
                        TypeRowView(total: total, of: model.breakdown.total)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            Divider().overlay(Color.hairline)
            TrashTray(model: model, working: working, onTrash: onTrash)
        }
        .background(Color.panel)
    }
}

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
            if !model.staged.isEmpty {
                HStack {
                    Text("\(model.staged.count) selected · \(ByteFormat.string(model.stagedBytes))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
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

            // No confirmation step: moving to the Trash is reversible, the button
            // says how much it will move, and the header shows what is in there.
            if model.trashedThisSession > 0 {
                Button { model.revealTrashInFinder() } label: {
                    Text("Moved \(ByteFormat.string(model.trashedThisSession)) to the Trash this session · show")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.ember.opacity(0.8))
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Open the Trash in Finder, where you can put items back or empty it")
            } else {
                Text("Items go to the Trash — you can put them back.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.33))
            }
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
                .padding(.horizontal, 7)
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


/// A hairline that fills as the scan works through the top-level folders, and
/// is simply absent the rest of the time — the clearest signal that a scan is
/// still running, and that it has finished.
private struct ScanProgressBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack(alignment: .leading) {
            if model.isScanning {
                Rectangle()
                    .fill(Color.ember.opacity(0.15))
                GeometryReader { geometry in
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.ember.opacity(0.8), Color.ember],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(2, geometry.size.width * model.scanCompletion.fraction))
                        .animation(.easeOut(duration: 0.2), value: model.scanCompletion.fraction)
                }
            }
        }
        .frame(height: model.isScanning ? 2 : 0)
        .animation(.easeOut(duration: 0.25), value: model.isScanning)
    }
}
