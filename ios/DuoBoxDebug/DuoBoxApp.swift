import SwiftUI

@main
struct DuoBoxApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .tint(.red)
        }
    }
}
