import SwiftUI

/// ホログラム雨衣ちゃん v0 の画面。SceneKit の窓＋状態ラベル＋ホームへ戻るボタン。
struct HologramView: View {
    var onExit: () -> Void
    @StateObject private var tracker = HeadTracker()

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            HologramSceneView(tracker: tracker)
                .ignoresSafeArea()

            // 状態ラベル（顔トラッキング中か、ドラッグ操作かが分かる）
            VStack {
                Text(tracker.statusText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                    .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            // 本番 RootView と同じ見た目の戻るボタン
            Button(action: onExit) {
                Image(systemName: "house.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
            .accessibilityLabel("ホームへ戻る")
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
    }
}
