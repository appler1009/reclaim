import AppKit

/// The "are you sure" step before anything moves to the Trash.
///
/// An `NSAlert` rather than SwiftUI's `confirmationDialog`, because only the
/// AppKit alert offers a suppression checkbox — the standard macOS way to say
/// "don't ask again" — and this is exactly the kind of repeated confirmation it
/// exists for.
enum TrashConfirmation {
    struct Answer {
        let proceed: Bool
        /// True when the user ticked the suppression box.
        let stopAsking: Bool
    }

    static func ask(items: [FileItem], bytes: UInt64, measure: SizeMeasure) -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = items.count == 1
            ? "Move “\(items[0].name)” to the Trash?"
            : "Move \(items.count) items to the Trash?"

        let preview = items.prefix(8)
            .map { "· \($0.path)  (\(ByteFormat.string($0.size(measure))))" }
            .joined(separator: "\n")
        let more = items.count > 8 ? "\n· and \(items.count - 8) more…" : ""
        alert.informativeText = """
            This frees \(ByteFormat.string(bytes)) once the Trash is emptied. \
            Nothing is deleted permanently.

            \(preview)\(more)
            """

        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"

        let response = alert.runModal()
        return Answer(proceed: response == .alertFirstButtonReturn,
                      stopAsking: alert.suppressionButton?.state == .on)
    }
}
