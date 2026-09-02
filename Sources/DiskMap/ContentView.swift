import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var confirming = false
    @State private var report: AppModel.DeleteReport?
    @State private var working = false

    var body: some View {
        ZStack {
            Color.ink.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar(model: model)
                Divider().overlay(Color.hairline)
                HStack(spacing: 0) {
                    MapPane(model: model)
                    Divider().overlay(Color.hairline)
                    ReclaimPane(model: model,
                                working: working,
                                onReclaim: { confirming = true })
                        .frame(width: 372)
                }
            }
            if model.phase != .ready { Overlay(model: model) }
        }
        .frame(minWidth: 1080, minHeight: 680)
        .preferredColorScheme(.dark)
        .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { performReclaim() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
        .alert("Reclaimed \(ByteFormat.string(report?.bytes ?? 0))",
               isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("Done") { report = nil }
        } message: {
            if let report {
                Text(report.failures.isEmpty
                     ? "\(report.trashed.count) item\(report.trashed.count == 1 ? "" : "s") moved to the Trash. Empty the Trash to free the space for good."
                     : "\(report.trashed.count) moved to the Trash. \(report.failures.count) could not be removed:\n"
                       + report.failures.prefix(3).map { "· \($0.0.name): \($0.1)" }.joined(separator: "\n"))
            }
        }
    }

    private var confirmTitle: String {
        "Move \(model.stagedItems.count) item\(model.stagedItems.count == 1 ? "" : "s") to the Trash?"
    }

    private var confirmMessage: String {
        let items = model.stagedItems
        let preview = items.prefix(6).map { "· \($0.path)  (\(ByteFormat.string($0.bytes)))" }
            .joined(separator: "\n")
        let more = items.count > 6 ? "\n· and \(items.count - 6) more…" : ""
        return "This frees \(ByteFormat.string(model.stagedBytes)) once the Trash is emptied. "
             + "Nothing is deleted permanently.\n\n" + preview + more
    }

    private func performReclaim() {
        working = true
        Task {
            let result = await model.reclaimStaged()
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
                Divider().frame(height: 22).overlay(Color.hairline)
                Metric(value: ByteFormat.string(model.scannedBytes), caption: "Scanned")
                Metric(value: "\(model.progress.filesScanned.formatted())", caption: "Files")
                if model.volumeCapacity > 0 {
                    Metric(value: ByteFormat.string(model.volumeFree), caption: "Free on volume")
                }
            }

            Spacer()

            if model.phase == .ready {
                Toggle(isOn: $model.focusWaste) { Text("Spotlight waste") }
                    .toggleStyle(.switch)
                    .tint(Color.ember)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))

                Picker("", selection: $model.measure) {
                    ForEach(SizeMeasure.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 132)

                Button { model.rescan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                    .buttonStyle(GhostButtonStyle())
            }
            Button { model.chooseFolder() } label: { Label("Choose folder…", systemImage: "folder") }
                .buttonStyle(GhostButtonStyle(tint: Color.ember))
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
                Button { model.zoomOut() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(GhostButtonStyle())
                    .disabled(model.zoomRoot === model.scanRoot)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, node in
                            if index > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            Button { model.zoomRoot = node } label: {
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

            TreemapRepresentable(model: model)
                .background(Color.ink)

            HoverBar(model: model)
        }
    }
}

private struct LegendStrip: View {
    var body: some View {
        HStack(spacing: 10) {
            ForEach(WasteCategory.allCases.prefix(4), id: \.self) { category in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: category.accent))
                        .frame(width: 9, height: 9)
                    Text(category.rawValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }
}

private struct HoverBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let item = model.hoverItem ?? model.selectedItem
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
                Text("Hover the map to inspect · double-click a folder to zoom in")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.32))
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(Color.panel.opacity(0.6))
    }
}

// MARK: - Reclaim pane

private struct ReclaimPane: View {
    @ObservedObject var model: AppModel
    var working: Bool
    var onReclaim: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HeroPanel(model: model)
            Divider().overlay(Color.hairline)

            if model.wasteGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 34)).foregroundStyle(Color.green.opacity(0.7))
                    Text("Nothing obviously wasted here")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Text("The treemap still shows what is using the space.")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.wasteGroups) { group in
                            GroupCard(model: model, group: group)
                        }
                    }
                    .padding(12)
                }
            }

            Divider().overlay(Color.hairline)
            VStack(spacing: 8) {
                HStack {
                    Text(model.stagedItems.isEmpty
                         ? "Nothing selected"
                         : "\(model.stagedItems.count) selected · \(ByteFormat.string(model.stagedBytes))")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if !model.stagedItems.isEmpty {
                        Button("Clear") { model.clearStaging() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Button(action: onReclaim) {
                    HStack(spacing: 7) {
                        if working { ProgressView().controlSize(.small) }
                        Image(systemName: "trash.fill")
                        Text(model.stagedBytes > 0
                             ? "Move \(ByteFormat.string(model.stagedBytes)) to Trash"
                             : "Move to Trash")
                    }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: !model.stagedItems.isEmpty && !working))
                .disabled(model.stagedItems.isEmpty || working)

                Text("Items go to the Trash — you can put them back.")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.33))
            }
            .padding(12)
        }
        .background(Color.panel)
    }
}

private struct HeroPanel: View {
    @ObservedObject var model: AppModel

    private var share: Double {
        guard model.scannedBytes > 0 else { return 0 }
        return min(1, Double(model.totalWaste) / Double(model.scannedBytes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Overline(text: "Reclaimable")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ByteFormat.string(model.totalWaste))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color.ember],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                Text("· \(Int(share * 100))% of scan")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
            }

            GeometryReader { geometry in
                HStack(spacing: 2) {
                    ForEach(model.wasteGroups) { group in
                        Rectangle()
                            .fill(Color(nsColor: group.category.accent))
                            .frame(width: max(2, geometry.size.width
                                              * CGFloat(Double(group.bytes) / Double(max(model.totalWaste, 1)))))
                    }
                    if model.wasteGroups.isEmpty { Rectangle().fill(Color.white.opacity(0.06)) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Button { model.stageAllSafe() } label: {
                    Label("Select safe categories", systemImage: "checkmark.circle")
                }
                .buttonStyle(GhostButtonStyle(tint: Color.ember))
                Spacer()
                if model.lastReclaimed > 0 {
                    Text("freed \(ByteFormat.string(model.lastReclaimed))")
                        .font(.system(size: 10)).foregroundStyle(.green.opacity(0.75))
                }
            }
        }
        .padding(16)
    }
}

private struct GroupCard: View {
    @ObservedObject var model: AppModel
    let group: WasteGroup

    private var expanded: Bool { model.expandedCategories.contains(group.category) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CheckBox(state: model.stageState(of: group)) { model.toggle(group: group) }

                Image(systemName: group.category.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: group.category.accent))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.category.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        if group.category.isSafe {
                            Text("SAFE")
                                .font(.system(size: 8, weight: .bold)).tracking(0.8)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.green.opacity(0.9))
                        } else {
                            Text("REVIEW")
                                .font(.system(size: 8, weight: .bold)).tracking(0.8)
                                .padding(.horizontal, 4).padding(.vertical, 1.5)
                                .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.orange.opacity(0.9))
                        }
                    }
                    Text("\(group.items.count) item\(group.items.count == 1 ? "" : "s") · \(group.category.blurb)")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(ByteFormat.string(group.bytes))
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { model.expandedCategories.remove(group.category) }
                else { model.expandedCategories.insert(group.category) }
            }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(group.items.prefix(40)) { item in
                        ItemRow(model: model, item: item)
                    }
                    if group.items.count > 40 {
                        Text("+ \(group.items.count - 40) smaller items included")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.35))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: group.category.accent).opacity(expanded ? 0.35 : 0.12), lineWidth: 1)
        )
    }
}

private struct ItemRow: View {
    @ObservedObject var model: AppModel
    let item: WasteItem

    var body: some View {
        HStack(spacing: 9) {
            CheckBox(state: model.isStaged(item)) { model.toggle(item) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).truncationMode(.middle)
                Text(item.reason)
                    .font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(ByteFormat.string(item.bytes))
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedItem = item.node; model.zoomRoot = item.node.parent ?? model.zoomRoot }
        .contextMenu {
            Button("Reveal in Finder") { model.revealInFinder(item.node) }
            Button(model.isStaged(item) ? "Unselect" : "Select for Trash") { model.toggle(item) }
        }
        .help(item.path)
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
                .frame(width: 15, height: 15)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.white.opacity(state == false ? 0.18 : 0), lineWidth: 1)
                )
                .overlay(
                    Group {
                        if state == true {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
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

// MARK: - Overlays

private struct Overlay: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ZStack {
            Color.ink.opacity(model.phase == .scanning ? 0.86 : 1).ignoresSafeArea()
            switch model.phase {
            case .idle:
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.3x3.topleft.filled")
                        .font(.system(size: 46)).foregroundStyle(Color.ember)
                    Text("Find the space worth reclaiming")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Scan a folder or volume. Every file becomes a tile sized by the space it takes,\nand anything safe to delete is called out for you.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button { model.scan(FileManager.default.homeDirectoryForCurrentUser) } label: {
                            Label("Scan Home folder", systemImage: "house.fill")
                        }
                        .buttonStyle(GhostButtonStyle(tint: Color.ember))
                        Button { model.chooseFolder() } label: {
                            Label("Choose folder…", systemImage: "folder")
                        }
                        .buttonStyle(GhostButtonStyle())
                    }
                    .padding(.top, 6)
                }
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
