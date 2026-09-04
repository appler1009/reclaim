import AppKit
import SwiftUI

/// The app's preferences, reached with ⌘,.
struct SettingsView: View {
    @AppStorage(NightlyRescan.enabledKey) private var nightlyEnabled = false
    @AppStorage(NightlyRescan.hourKey) private var nightlyHour = NightlyRescan.defaultHour
    @ObservedObject private var watchlist = Watchlist.shared
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
                            Button(volume.name) { watchlist.add(volume.url.path) }
                                .disabled(watchlist.contains(volume.url.path))
                        }
                    }
                    .frame(width: 130)
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
    func settingsFootnote() -> some View {
        font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
