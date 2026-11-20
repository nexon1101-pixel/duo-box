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
                // デバッグ版は、操作系の色も赤に寄せる
                .tint(BoxTint.color)
        }
    }
}

/// デバッグ版（IDに .debug を含む）だけ赤、それ以外は標準のアクセント色。
private enum BoxTint {
    static var color: Color {
        Bundle.main.bundleIdentifier?.contains(".debug") == true ? .red : .accentColor
    }
}
