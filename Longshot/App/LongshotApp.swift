import SwiftUI

@main
struct LongshotApp: App {
    @State private var model = StitchViewModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
        }
    }
}
