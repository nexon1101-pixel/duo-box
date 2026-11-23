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
    /// 箱の確認の段の間はホームボタンを隠す（下パネルが透明になり、箱に重なるため）
    @State private var hideHomeButton = false
    /// 状態ラベルの表示が変わった時刻（この時刻から数秒だけ出す）
    @State private var statusChangedAt = Date()
    static let statusVisibleSeconds: TimeInterval = 3

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
            return "\(line)｜折り角 \(Int(deg.rounded()))°"
        }
        return "\(line)｜折り角が取れません（全開として表示）"
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

            // 状態ラベル。顔を追えているあいだは 3 秒で消し、見失ったときや状態が変わったときだけ出す
            // （上の画面の真ん中に出しっぱなしだと、人形や部屋に重なって邪魔なため）
            VStack {
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    let tracking = tracker.mode == .tracking
                    let recent = context.date.timeIntervalSince(statusChangedAt) < Self.statusVisibleSeconds
                    Text(statusLine)
                        .multilineTextAlignment(.center)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .opacity(!tracking || recent ? 1 : 0)
                        .animation(.easeOut(duration: 0.4), value: !tracking || recent)
                }
                .padding(.top, 6)
                .padding(.horizontal, 16)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)

            if !diagnostics.isCalibrated {
                Text("初回の設定が未完了です（三本指でタップ → キャリブレーション）")
                    .font(.caption)
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
            // 比べる場面と L 字の箱では、下パネルの十字・棒・箱に重なるので出さない
            // 回転台のように人形をゆっくり回す（立体感の確認用）。ホームボタンの左に置く
            if !hideHomeButton && !showCompare && !showLBox {
                Button { diagnostics.dance.toggle() } label: {
                    Image(systemName: diagnostics.dance ? "pause.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .accessibilityLabel(diagnostics.dance ? "回すのを止める" : "ゆっくり回す")
                .padding(.trailing, 20 + 48 + 14)
                .padding(.bottom, 20)
            }

            if !hideHomeButton && !showCompare && !showLBox {
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

            if showCalibration {
                HologramCalibrationFlow(tracker: tracker, diagnostics: diagnostics,
                                        onClose: { showCalibration = false },
                                        onHomeButtonHidden: { hideHomeButton = $0 })
            }

            if showCompare {
                HologramCompareView(tracker: tracker, diagnostics: diagnostics,
                                    onFinish: { showCompare = false })
            }
        }
        .onAppear { tracker.start() }
        .onDisappear { tracker.stop() }
        .onChange(of: tracker.mode) { _, _ in statusChangedAt = Date() }
        .onReceive(hinge.$angleDegrees) { deg in
            let next = Self.nextNeedsOpen(current: needsOpen, angleDeg: deg)
            if next != needsOpen { needsOpen = next }
        }
    }
}
