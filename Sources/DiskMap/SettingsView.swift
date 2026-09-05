import AppKit
import ReclaimKit
import SwiftUI

/// The app's preferences, reached with ⌘,.
struct SettingsView: View {
    @AppStorage(NightlyRescan.enabledKey) private var nightlyEnabled = false
    @AppStorage(NightlyRescan.hourKey) private var nightlyHour = NightlyRescan.defaultHour
    @ObservedObject private var watchlist = Watchlist.shared
    @ObservedObject private var companion = CompanionService.shared
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        Form {
            Section {
                Toggle("Rescan overnight", isOn: $nightlyEnabled)
                Picker("At", selection: $nightlyHour) {
                    ForEach(0 ..< 24, id: \.self) { hour in
                        Text(Self.label(forHour: hour)).tag(hour)
                    }
                }
                .disabled(!nightlyEnabled)
                .frame(width: 200)
            } footer: {
                // Said plainly rather than discovered by a user wondering why
                // the numbers are a week old: this schedule lives in the app.
                Text("Each open window rescans what it is showing, so the morning's "
                     + "numbers are current and history gains a point a day. Runs only "
                     + "while Reclaim is open, and is skipped for a window holding items "
                     + "picked for the Trash.")
                    .settingsFootnote()
            }

            Section {
                if watchlist.targets.isEmpty {
                    Text("Nothing is watched. Add a disk or a folder to keep measuring it "
                         + "without leaving a window open for it.")
                        .settingsFootnote()
                } else {
                    ForEach(watchlist.targets, id: \.self) { target in
                        WatchedRow(target: target) { watchlist.remove(target) }
                    }
                }

                HStack(spacing: 10) {
                    Button("Add Folder…") { chooseFolder() }
                    Menu("Add Volume") {
                        ForEach(volumes) { volume in
                            Button { watchlist.add(volume.url.path) } label: {
                                // A tick rather than a silently dead row: a
                                // volume already watched is disabled, and the
                                // menu should say which of the two it is.
                                if watchlist.contains(volume.url.path) {
                                    Label(Self.label(for: volume), systemImage: "checkmark")
                                } else {
                                    Text(Self.label(for: volume))
                                }
                            }
                            .disabled(watchlist.contains(volume.url.path))
                        }
                    }
                    // Sized to its own label, so the chevron sits against the
                    // words rather than adrift at the end of a fixed width.
                    .fixedSize()
                    .disabled(volumes.isEmpty)
                    Spacer()
                }
            } header: {
                Text("Watched")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Watched disks and folders are rescanned at the hour above whether "
                         + "or not a window is showing them. That is what gives history more "
                         + "than one point, so Reclaim can say what grew and where the free "
                         + "space went. A watched disk that is not mounted is skipped.")
                        .settingsFootnote()
                    if !watchlist.targets.isEmpty && !nightlyEnabled {
                        Label("Turn on Rescan overnight for these to run.",
                              systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(Color.caution)
                    }
                }
            }

            Section {
                CompanionSection(companion: companion)
            } header: {
                Text("Companion")
            } footer: {
                Text("With this on, Reclaim answers on your local network so the iPhone "
                     + "app can show what your open tabs are showing, and an agent on a "
                     + "paired device can ask the same questions one on this Mac can. "
                     + "A device gets in once, by typing a code shown here. "
                     + "The address on this Mac stays open to this Mac either way.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        // Read when the pane opens rather than held live: the list is short,
        // and a settings window is not the place to watch disks come and go.
        .onAppear { volumes = VolumeScanner.mounted() }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a disk or folder to keep measuring overnight."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watchlist.add(url.path)
    }

    /// Names alone do not identify a disk: two can be called Untitled, and a
    /// backup clone usually carries the name of what it copied. Size and mount
    /// point are what tell them apart, so the menu says all three.
    static func label(for volume: VolumeInfo) -> String {
        "\(volume.name) — \(ByteFormat.string(volume.capacity)) · \(volume.url.path)"
    }

    /// The hour in the user's own clock convention, so a 12-hour locale is not
    /// asked to think in 15:00.
    static func label(forHour hour: Int) -> String {
        guard let date = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1,
                                                                     hour: hour, minute: 0)) else {
            return "\(hour):00"
        }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: date)
    }
}

/// Turning the network service on, offering a code, and the devices already let in.
private struct CompanionSection: View {
    @ObservedObject var companion: CompanionService
    @ObservedObject private var paired: PairedDevices
    @State private var enabled: Bool

    init(companion: CompanionService) {
        self.companion = companion
        self.paired = companion.paired
        // Read once from defaults rather than through @AppStorage: the toggle
        // has to start and stop a server, not only write a flag, so the service
        // is the one that owns this setting.
        _enabled = State(initialValue: companion.isEnabled)
    }

    var body: some View {
        Toggle("Answer on this network", isOn: $enabled)
            .onChange(of: enabled) { _, on in companion.setEnabled(on) }

        if let failure = companion.failure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(Color.caution)
        }

        if companion.isRunning {
            LabeledContent("Address") {
                Text(companion.address)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        }

        if let offer = companion.offer, offer.isOpen() {
            VStack(alignment: .leading, spacing: 6) {
                Text(spaced(offer.code))
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                Text("Type this in the Reclaim app on your phone. It lasts three "
                     + "minutes and pairs one device.")
                    .settingsFootnote()
                Button("Stop Offering") { companion.cancelPairing() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Button("Pair a Device…") { companion.offerPairing() }
                    .disabled(!companion.isRunning)
                Spacer()
            }
        }

        ForEach(paired.devices) { device in
            PairedRow(device: device) { paired.forget(device) }
        }
    }

    /// Read aloud and typed on a phone, so it is grouped rather than run together.
    private func spaced(_ code: String) -> String {
        let middle = code.index(code.startIndex, offsetBy: min(3, code.count))
        return code[..<middle] + " " + code[middle...]
    }
}

/// One device that has been let in, and a way to change that.
private struct PairedRow: View {
    let device: PairedDevices.Device
    let forget: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(action: forget) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.ember : .secondary)
            }
            .buttonStyle(.plain)
            .help("Stop letting \(device.name) in")
        }
        .onHover { hovering = $0 }
    }

    private var subtitle: String {
        guard let seen = device.lastSeen else { return "paired \(Self.when(device.pairedAt))" }
        return "last seen \(Self.when(seen))"
    }

    private static func when(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One watched target: what it is, where it is, and a way to stop watching it.
private struct WatchedRow: View {
    let target: String
    let remove: () -> Void
    @State private var hovering = false

    private var url: URL { URL(fileURLWithPath: target) }
    /// A volume's name is its last component; "/" has none, so it says so.
    private var name: String {
        let last = url.lastPathComponent
        return last.isEmpty || last == "/" ? "Startup disk" : last
    }
    private var exists: Bool { FileManager.default.fileExists(atPath: target) }

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target))
                .resizable().frame(width: 18, height: 18)
                .opacity(exists ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(abbreviated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !exists {
                // Not an error worth a dialog: an external disk is unplugged
                // more often than a watched folder is deleted.
                Text("not mounted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(hovering ? Color.ember : .secondary)
            }
            .buttonStyle(.plain)
            .help("Stop watching \(target)")
        }
        .onHover { hovering = $0 }
    }

    /// The home folder written the way people write it.
    private var abbreviated: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard target.hasPrefix(home) else { return target }
        return "~" + target.dropFirst(home.count)
    }
}

private extension View {
    /// The explanatory small print under a settings section.
    ///
    /// Pushed left on purpose: a grouped `Form` puts a footer in the trailing
    /// value column, where a paragraph comes out ragged-left against the right
    /// edge and reads as though it belongs to whatever control sits above it.
    /// Prose in this window starts at the same margin as everything else.
    func settingsFootnote() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
