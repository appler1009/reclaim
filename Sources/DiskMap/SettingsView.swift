import SwiftUI

/// The app's preferences, reached with ⌘,.
struct SettingsView: View {
    @AppStorage(NightlyRescan.enabledKey) private var nightlyEnabled = false
    @AppStorage(NightlyRescan.hourKey) private var nightlyHour = NightlyRescan.defaultHour

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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
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
