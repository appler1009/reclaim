import SwiftUI

@main
struct ReclaimCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            MacsView()
                .tint(Theme.ember)
                .preferredColorScheme(.dark)
        }
    }
}
