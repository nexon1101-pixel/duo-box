import SwiftUI

/// ホログラム雨衣ちゃん v0 の画面。SceneKit の窓＋状態ラベル＋ホームへ戻るボタン。
struct HologramView: View {
    var onExit: () -> Void
    @StateObject private var tracker = HeadTracker()
    @StateObject private var hinge = HingeMonitor()
    @StateObject private var diagnostics = HologramDiagnostics()
    /// 計測パネルの表示（三本指タップで開閉）
    @State private var showDebugPanel = false
    /// 「画面を開いてください」の表示中か（ヒステリシスのため状態で持つ）
    @State private var needsOpen = false
    /// キャリブレーション画面の表示
    @State private var showCalibration = false
    /// 本物の物と比べる場面（計測パネルから単独で開く）
    @State private var showCompare = false
    /// L 字の確認の箱（計測パネルから単独で開く）
    @State private var showLBox = false

    /// この角度未満で「画面を開いてください」を出し、この角度以上で消す。間は前の状態を保つ
    static let openPromptShowBelowDeg: Double = 60
    static let openPromptHideAtDeg: Double = 70

    /// 状態ラベル。ヒンジ角度が取れていれば併記する（取れなければ全開 180° 扱い）
    private var statusLine: String {
        var line = tracker.statusText
        // 顔が見つからない状態が続くときの手がかり：最後に捉えてからの秒数
        if tracker.mode == .searching {
            if let sec = tracker.secondsSinceFace { line += "（最後に捕捉から\(sec)秒）" }
            else { line += "（まだ一度も捕捉なし）" }
        }
        if let deg = hinge.angleDegrees {
            return "\(line)｜ヒンジ \(Int(deg.rounded()))°"
        }
        return "\(line)｜ヒンジ角度なし（全開扱い）"
    }

    /// 次の表示状態。角度が取れなければ開いている扱い（出さない）
    private static func nextNeedsOpen(current: Bool, angleDeg: Double?) -> Bool {
        guard let deg = angleDeg else { return false }
        if deg < openPromptShowBelowDeg { return true }
        if deg >= openPromptHideAtDeg { return false }
        return current
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // シーンは常時マウントしたまま（作り直すとモデル約41MBの読み直しになる）
            HologramSceneView(tracker: tracker, hinge: hinge, diagnostics: diagnostics,
                              onThreeFingerTap: { showDebugPanel.toggle() })
                .ignoresSafeArea()

            if needsOpen {
                Color.black
                    .ignoresSafeArea()
                Text("画面を開いてください")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            // 状態ラベル（顔トラッキング中か、ドラッグ操作かが分かる）
            VStack {
                // 秒数を1秒ごとに更新するため TimelineView で包む
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(statusLine)
                        .multilineTextAlignment(.center)
                }
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

            if !diagnostics.isCalibrated {
                Text("キャリブレーション未実施")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }

            if showLBox {
                HologramLBoxView(hinge: hinge, diagnostics: diagnostics,
                                 onClose: { showLBox = false })
            }

            // 計測パネル（三本指タップで開閉）
            if showDebugPanel {
                HologramDebugPanel(hinge: hinge, tracker: tracker, diagnostics: diagnostics,
                                   onCalibrate: { showDebugPanel = false; showLBox = false; showCalibration = true },
                                   onCompare: { showDebugPanel = false; showLBox = false; showCompare = true },
                                   isLBoxOpen: showLBox,
                                   onToggleLBox: {
                                       showDebugPanel = false
                                       showCalibration = false
                                       showCompare = false
                                       showLBox.toggle()
                                   },
                                   onClose: { showDebugPanel = false })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

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

            if showCalibration {
                HologramCalibrationFlow(tracker: tracker, diagnostics: diagnostics,
                                        onClose: { showCalibration = false })
            }

            if showCompare {
                HologramCompareView(tracker: tracker, diagnostics: diagnostics,
                                    onFinish: { showCompare = false })
            }
        }
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
        .onReceive(hinge.$angleDegrees) { deg in
            let next = Self.nextNeedsOpen(current: needsOpen, angleDeg: deg)
            if next != needsOpen { needsOpen = next }
        }
    }
}
