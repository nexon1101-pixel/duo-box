import DuoRemoteCore
import SwiftUI

@main
struct DuoBoxApp: App {
    @StateObject private var session = RemoteSession()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                // 映像を見る機能が中心なので、いつも暗い見た目にする
                .preferredColorScheme(.dark)
        }
    }
}
