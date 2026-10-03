import SwiftUI

@main
@MainActor
struct BreatheApp: App {
    @State private var pacer = PacerModel()

    var body: some Scene {
        WindowGroup {
            PacerScreen()
                .environment(pacer)
        }
    }
}
