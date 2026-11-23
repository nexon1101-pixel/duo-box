import simd
import SwiftUI
import UIKit

/// 上下左右へ 0.5mm ずつ動かすボタン。move は (右へ mm, 下へ mm)
struct CalibrationNudgePad: View {
    static let stepMM: Double = 0.5
    let move: (_ rightMM: Double, _ downMM: Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            button("chevron.up", "上へ 0.5mm") { move(0, -Self.stepMM) }
            HStack(spacing: 4) {
                button("chevron.left", "左へ 0.5mm") { move(-Self.stepMM, 0) }
                Text("0.5mm").font(.caption2).frame(width: 48)
                button("chevron.right", "右へ 0.5mm") { move(Self.stepMM, 0) }
            }
            button("chevron.down", "下へ 0.5mm") { move(0, Self.stepMM) }
        }
    }

    private func button(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 44, height: 36)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }
}

/// キャリブレーションの最初の段：映像を 0°・90°・180°・270° 回して並べ、顔がまっすぐなものを選ぶ。
struct HologramOrientationView: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onDecide: () -> Void
    var onCancel: () -> Void

    /// 見本1枚の元の映像の大きさ（正方形なので、回しても切れ方が変わらない）
    private static let sourceSize = CGSize(width: 240, height: 240)

    @StateObject private var feed = CalibrationFeed()
    @State private var selected: Int?

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            let spacing: CGFloat = 8
            let tile = max(min((geo.size.width - spacing * 5) / 4, fold - 24), 40)
            let current = selected ?? tracker.videoTurns
            ZStack(alignment: .topLeading) {
                Color.black
                HStack(spacing: spacing) {
                    ForEach(0..<4, id: \.self) { turns in
                        Button { selected = turns } label: { preview(turns: turns, size: tile, isSelected: current == turns) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(turns * 90)度")
                            .accessibilityAddTraits(current == turns ? .isSelected : [])
                    }
                }
                .frame(width: geo.size.width, height: fold)

                ScrollView {
                    VStack(spacing: 12) {
                        Text("顔がまっすぐ（あごが下）に映っているものを選んでください")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 24) {
                            Button("やめる", action: onCancel)
                            Button("決定") {
                                diagnostics.chooseVideoTurns(current, tracker: tracker)
                                onDecide()
                            }
                            .bold()
                        }
                    }
                    .padding(14)
                }
                .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
                .offset(y: fold)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear { tracker.setCalibrationFeed(feed, viewport: Self.sourceSize, unrotated: true) }
        .onDisappear { tracker.setCalibrationFeed(nil, viewport: .zero) }
    }

    private func preview(turns: Int, size: CGFloat, isSelected: Bool) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = feed.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .rotationEffect(.degrees(Double(turns) * 90))
                        .scaleEffect(x: -1, y: 1)   // 回したあとに鏡映しにする（顔合わせの画面と同じ順番）
                } else {
                    Color.white.opacity(0.1)
                }
            }
            .frame(width: size, height: size)
            .clipped()
            Text("\(turns * 90)°")
                .font(.caption.bold())
                .padding(.horizontal, 5)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(4)
        }
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.25),
                                                                lineWidth: isSelected ? 3 : 1))
    }
}

/// G2：アプリが思っているカメラの位置に輪を出し、実物のカメラの点へ合わせる画面。
/// ARKit は動かしたままにして、システムのカメラの印（黒い楕円）を目印にする。
struct HologramCameraAlignView: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    /// 決定したあとに呼ぶ
    var onDecide: () -> Void
    var onCancel: () -> Void

    @State private var belowTopMM: Double = HologramDeviceProfile.defaultCameraBelowTopMM
    @State private var rightMM: Double = HologramDeviceProfile.defaultCameraRightMM
    /// 「occlusion の値に戻す」を選んだ状態。決定すると手で合わせた値を消す
    @State private var useOcclusion = false
    @State private var loaded = false
    @State private var dragStart: (below: Double, right: Double)?

    private var mmPerPt: Double { HologramDeviceProfile.mmPerPoint }

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Color.black

                // 上パネル全体をドラッグの受け口にする（指で輪を隠さないため、動かした分だけ輪が動く）
                // 黒い楕円が見えるよう、上パネルは灰色にする
                Color(white: 0.45)
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: fold)
                    .gesture(dragGesture(width: geo.size.width, fold: fold))

                Circle()
                    .strokeBorder(.yellow, lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().fill(.yellow).frame(width: 3, height: 3))
                    .position(x: geo.size.width / 2 + rightMM / mmPerPt, y: belowTopMM / mmPerPt)
                    .allowsHitTesting(false)

                controls
                    .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
                    .offset(y: fold)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear {
            tracker.start()   // 動いていれば何もしない
            loadCurrent()
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("黄色い輪の中心を、カメラの位置（左端に出ている黒い楕円の中心）に合わせて、決定を押してください")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(HologramDeviceProfile.cameraPositionText(belowTopMM: belowTopMM, rightMM: rightMM))
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.center)
                CalibrationNudgePad { right, down in
                    rightMM += right
                    belowTopMM = max(belowTopMM + down, 0)
                    useOcclusion = false
                }
                HStack {
                    Button("occlusion の値に戻す", action: resetToOcclusion)
                        .disabled(diagnostics.cameraProfile.occlusionBelowTopMM == nil)
                    Button("左右を反転した値にする") {
                        rightMM = -rightMM
                        useOcclusion = false
                    }
                }
                .font(.caption)
                HStack(spacing: 24) {
                    Button("やめる", action: onCancel)
                    Button("決定", action: decide).bold()
                }
            }
            .padding(14)
        }
    }

    private func dragGesture(width: CGFloat, fold: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? (below: belowTopMM, right: rightMM)
                dragStart = start
                let halfWidthMM = Double(width) / 2 * mmPerPt
                rightMM = min(max(start.right + Double(value.translation.width) * mmPerPt, -halfWidthMM), halfWidthMM)
                belowTopMM = min(max(start.below + Double(value.translation.height) * mmPerPt, 0), Double(fold) * mmPerPt)
                useOcclusion = false
            }
            .onEnded { _ in dragStart = nil }
    }

    private func loadCurrent() {
        guard !loaded else { return }
        loaded = true
        belowTopMM = diagnostics.cameraProfile.cameraBelowTopMM
        rightMM = diagnostics.cameraProfile.cameraRightMM
    }

    private func resetToOcclusion() {
        let p = diagnostics.cameraProfile
        guard let below = p.occlusionBelowTopMM, let right = p.occlusionRightMM else { return }
        belowTopMM = below
        rightMM = right
        useOcclusion = true
    }

    private func decide() {
        if useOcclusion {
            diagnostics.clearManualCamera()
        } else {
            diagnostics.saveManualCamera(belowTopMM: belowTopMM, rightMM: rightMM)
        }
        onDecide()
    }
}

/// 向き → G2 → G3 → G4 → 本物の物と比べる場面 を通しで進める画面。
struct HologramCalibrationFlow: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onClose: () -> Void
    /// 箱の確認の段の間、ホームボタンを隠すかどうか
    var onHomeButtonHidden: (Bool) -> Void

    private enum Step { case orientation, camera, axis, box, compare }
    @State private var step = Step.orientation

    var body: some View {
        switch step {
        case .orientation:
            HologramOrientationView(tracker: tracker, diagnostics: diagnostics,
                                    onDecide: { step = .camera },
                                    onCancel: onClose)
        case .camera:
            HologramCameraAlignView(tracker: tracker, diagnostics: diagnostics,
                                    onDecide: { step = .axis },
                                    onCancel: onClose)
        case .axis:
            HologramAxisCalibrationView(tracker: tracker, diagnostics: diagnostics,
                                        onNext: { step = .box }, onFinish: onClose)
        case .box:
            HologramBoxCheckView(diagnostics: diagnostics,
                                 onRetry: { step = .camera }, onNext: { step = .compare }, onFinish: onClose,
                                 onHomeButtonHidden: onHomeButtonHidden)
        case .compare:
            HologramCompareView(tracker: tracker, diagnostics: diagnostics, onFinish: onClose)
        }
    }
}

/// G4：画面の奥 30mm の L 字の格子の箱で、最後の確認をする。
/// 箱全体が見えるよう、質問と回答は下パネルの手前の端の細い帯にまとめ、帯のタップで隠したり出したりする
struct HologramBoxCheckView: View {
    @ObservedObject var diagnostics: HologramDiagnostics
    var onRetry: () -> Void
    /// 「はい」のあと、本物の物と比べる場面へ進む
    var onNext: () -> Void
    var onFinish: () -> Void
    /// この段の間、ホームボタンを隠すかどうかを親へ伝える（箱に重ならないように）
    var onHomeButtonHidden: (Bool) -> Void
    @State private var answeredNo = false
    @State private var isBandHidden = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // 帯の外の下パネルは透明にして箱を見せる。タッチは今までどおりシーンへ通さない
            GeometryReader { geo in
                let profileFold = diagnostics.cameraProfile.foldYPt
                let fold = profileFold > 0 ? profileFold : geo.size.height / 2
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
                    .offset(y: fold)
            }
            .ignoresSafeArea()

            if isBandHidden {
                showBandHandle
            } else {
                answerBand
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            diagnostics.rig?.setCheckMode(true)
            onHomeButtonHidden(true)
        }
        .onDisappear {
            diagnostics.rig?.setCheckMode(false)
            onHomeButtonHidden(false)
        }
    }

    /// 質問と回答の帯。ボタン以外の場所をタップすると隠れる
    private var answerBand: some View {
        HStack(spacing: 10) {
            Text(answeredNo ? "カメラ位置と軸を合わせ直してください" : "片目で頭を左右に：箱は奥に止まって見える？")
                .font(.footnote.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
            if answeredNo {
                bandButton("閉じる", action: onFinish)
                bandButton("やり直す", isBold: true, action: onRetry)
                    .accessibilityLabel("カメラ位置からやり直す")
            } else {
                bandButton("いいえ") { answer(false) }
                bandButton("はい", isBold: true) { answer(true) }
            }
            Button { isBandHidden = true } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 32, height: 44)
            }
            .accessibilityLabel("質問を隠す")
        }
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.55).ignoresSafeArea(edges: .bottom))
        .contentShape(Rectangle())
        .onTapGesture { isBandHidden = true }
    }

    /// 帯を隠している間の小さな取っ手。押せる範囲は帯と同じ高さにする
    private var showBandHandle: some View {
        Button { isBandHidden = false } label: {
            Image(systemName: "chevron.up")
                .font(.caption2.bold())
                .frame(width: 56, height: 18)
                .background(Color.black.opacity(0.4), in: Capsule())
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .bottom)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("質問を出す")
    }

    private func bandButton(_ title: String, isBold: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isBold ? .bold : .regular)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
    }

    private func answer(_ yes: Bool) {
        HologramCalibrationStore.saveBoxCheck(yes, machineID: HologramDeviceProfile.readMachineID())
        diagnostics.boxCheck = yes
        if yes { onNext() } else { answeredNo = true }
    }
}

/// 計測パネルから開く L 字の確認の箱。箱を隠さないよう、下パネルの下側にヒンジ角と閉じるボタンだけを出す
struct HologramLBoxView: View {
    @ObservedObject var hinge: HingeMonitor
    @ObservedObject var diagnostics: HologramDiagnostics
    var onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            HStack(spacing: 20) {
                VStack(spacing: 0) {
                    Text("ヒンジ角").font(.caption)
                    Text(hinge.angleDegrees.map { "\(Int($0.rounded()))°" } ?? "取得なし")
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
                Button("箱を閉じる", action: onClose)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .padding(.bottom, 12)
            .frame(width: geo.size.width, height: max(geo.size.height - fold, 0), alignment: .bottom)
            .offset(y: fold)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear { diagnostics.rig?.setLBoxMode(true) }
        .onDisappear { diagnostics.rig?.setLBoxMode(false) }
    }
}

/// 本物の物と仮想の棒を横に並べて、先読みを合わせる場面。
/// 十字と棒を隠さないよう、操作は上パネルの上側だけに置く。決定するまで保存しない
struct HologramCompareView: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onFinish: () -> Void

    private static let predictionButtonStepMS: Double = 5
    @State private var rodCM: Double = 4
    @State private var predictionMS: Double = 20

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            ScrollView { controls.padding(12) }
                .frame(width: geo.size.width, height: max(fold * 0.62, 0))
                .background(Color.black.opacity(0.85))
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear {
            tracker.start()   // 動いていれば何もしない
            predictionMS = min(diagnostics.oePredMS, HologramCalibrationStore.predictionRangeMS.upperBound)
            diagnostics.rig?.setCompareRodHeight(Float(rodCM / 100))
            diagnostics.rig?.setCompareMode(true)
        }
        .onDisappear {
            // 決定していなければ、保存済みの値へ戻る
            diagnostics.rig?.setCompareMode(false)
            diagnostics.rig?.setOneEuroPred(Float(diagnostics.oePredMS / 1000))
        }
        .onChange(of: rodCM) { _, v in diagnostics.rig?.setCompareRodHeight(Float(v / 100)) }
        .onChange(of: predictionMS) { _, v in diagnostics.rig?.setOneEuroPred(Float(v / 1000)) }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Text("十字の上に、ペンのキャップなどを立て、仮想の棒の高さをキャップに合わせてください。片目を閉じて頭をゆっくり動かし、2本の先の並びが変わらなければ合っています")
                .font(.subheadline.bold())
                .multilineTextAlignment(.center)
            if tracker.mode != .tracking {
                Text("顔が見えていません").font(.caption).foregroundStyle(.orange)
            }
            predictionControls
            HStack {
                Text("棒の高さ \(String(format: "%.1f", rodCM)) cm").font(.caption)
                Slider(value: $rodCM, in: 2...6, step: 0.5)
            }
            HStack(spacing: 28) {
                Button("やめる", action: onFinish)
                Button("決定", action: decide).bold()
            }
        }
    }

    private var predictionControls: some View {
        VStack(spacing: 6) {
            Text("先読み \(String(format: "%.0f", predictionMS)) ms").font(.caption.bold())
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                Text("平均の遅れ：\(latencyText)").font(.caption2)
            }
            HStack {
                Button("仮想の方が\n遅れる") { nudgePrediction(Self.predictionButtonStepMS) }
                Button("仮想の方が\n先に動く") { nudgePrediction(-Self.predictionButtonStepMS) }
            }
            .font(.caption)
            .buttonStyle(.bordered)
            Slider(value: $predictionMS, in: HologramCalibrationStore.predictionRangeMS, step: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var latencyText: String {
        diagnostics.rig?.averageLatencyMS.map { String(format: "%.0f ms", $0) } ?? "—"
    }

    private func nudgePrediction(_ delta: Double) {
        let r = HologramCalibrationStore.predictionRangeMS
        predictionMS = min(max(predictionMS + delta, r.lowerBound), r.upperBound)
    }

    private func decide() {
        diagnostics.oePredMS = predictionMS
        onFinish()
    }
}

/// G3 の進行と判定。座標はすべて「カメラから見た目の位置」で扱う。
final class AxisCalibrationModel: ObservableObject {
    enum Stage: Int { case front, right, backFromRight, up, backFromUp, near, verify }
    enum FrameState { case noFace, off, matched }

    /// 映像の上に出す顔の枠と目印（ビューの pt）
    struct FaceGuide: Equatable {
        var center: CGPoint
        var size: CGSize
        var leftEye: CGPoint
        var rightEye: CGPoint
        var angle: Double      // ラジアン
    }

    static let frontDistance: Float = 0.35       // 正面の目標の距離（m）
    static let frontRange: ClosedRange<Float> = 0.30...0.40
    static let stepDistance: Float = 0.10        // 右・上・近づくの目標の移動量（m）
    static let recordMove: Float = 0.08          // 目印に合わなくても記録する移動量（m）
    static let minimumMove: Float = 0.04         // これ未満はやり直し（m）
    static let stillRadius: Float = 0.012        // 止まっているとみなす揺れ（m）
    static let returnRadius: Float = 0.03        // 正面へ戻ったとみなす距離（m）
    static let matchRadius: Float = 0.015        // 目の中点の許容（m）
    static let matchDistance: Float = 0.03       // 距離の許容（m）
    static let tiltLimitDegrees = 15.0           // これ以上の傾きは「まっすぐに」と案内する
    static let eyeSpacing: Float = 0.063         // 両目の間隔（m）
    static let faceWidth: CGFloat = 0.15         // 枠の幅（m）
    static let faceHeight: CGFloat = 0.21        // 枠の高さ（m）
    static let faceCenterBelowEyes: CGFloat = 0.03 // 目の線から枠の中心までの距離（m）
    static let frontHold: TimeInterval = 2
    static let stepHold: TimeInterval = 1

    @Published private(set) var stage = Stage.front
    @Published private(set) var message = ""
    @Published private(set) var instruction = "枠の中に顔を入れてください"
    @Published private(set) var guide: FaceGuide?
    @Published private(set) var detectedLeft: CGPoint?
    @Published private(set) var detectedRight: CGPoint?
    @Published private(set) var frameState = FrameState.noFace
    @Published private(set) var canUseAsBase = false
    @Published private(set) var resultText: String?
    @Published var belowTopMM: Double
    @Published var rightMM: Double
    @Published var overlayFlip: Bool
    /// カメラのオフセットを動かした分だけ映像をずらす量。枠は画面の同じ場所に残る
    @Published private(set) var videoShift = CGSize.zero
    @Published private(set) var canDecideFront = false

    private let machineID = HologramDeviceProfile.readMachineID()
    private var window: [CalibrationFeed.Sample] = []
    private var matchedSince: TimeInterval?
    private var baseScreen = SIMD3<Float>.zero
    private var baseCamera = SIMD3<Float>.zero
    private var rightMove: (axis: Int, sign: Float, camera: String)?
    private var upMove: (axis: Int, sign: Float, camera: String)?
    /// 画面を開いたときのオフセット。枠の表示位置の基準
    private let shiftBaseBelowMM: Double
    private let shiftBaseRightMM: Double
    /// 保存済みのオフセット。保存せずに進むときはここへ戻す
    private var committedBelowMM: Double
    private var committedRightMM: Double
    private var upperHeightMM: Double = 0

    init(belowTopMM: Double, rightMM: Double) {
        self.belowTopMM = belowTopMM
        self.rightMM = rightMM
        shiftBaseBelowMM = belowTopMM
        shiftBaseRightMM = rightMM
        committedBelowMM = belowTopMM
        committedRightMM = rightMM
        overlayFlip = HologramCalibrationStore.overlayFlip(machineID: HologramDeviceProfile.readMachineID())
    }

    var title: String {
        switch stage {
        case .front: return "端末の正面を向いたまま、ボタンで水色の点を目印に合わせて、決定してください"
        case .right: return "枠に合わせて、顔を右へ動かしてください"
        case .backFromRight, .backFromUp: return "枠に合わせて、顔を正面へ戻してください"
        case .up: return "枠に合わせて、顔を上へ動かしてください"
        case .near: return "枠に合わせて、顔を近づけてください"
        case .verify: return "確認：端末の正面に顔を置くと、目が目印に合いますか"
        }
    }

    /// 進み具合の丸（正面・右・上・近づく）のうち、済んだ数
    var completedSteps: Int {
        switch stage {
        case .front: return 0
        case .right: return 1
        case .backFromRight, .up: return 2
        case .backFromUp, .near: return 3
        case .verify: return 4
        }
    }

    /// いまの段の目標（カメラから見た位置、軸対応後の座標）
    private func target(upperHeightMM: Double) -> SIMD3<Float> {
        var t = Self.frontGoal(belowTopMM: belowTopMM, rightMM: rightMM, upperHeightMM: upperHeightMM)
        switch stage {
        case .right: t.x += Self.stepDistance
        case .up: t.y += Self.stepDistance
        case .near: t.z -= Self.stepDistance
        case .front, .backFromRight, .backFromUp, .verify: break
        }
        return t
    }

    /// 基本位置：上パネル中央の正面 35cm を、カメラから見た位置にしたもの（端末座標での定義は固定）
    private static func frontGoal(belowTopMM: Double, rightMM: Double, upperHeightMM: Double) -> SIMD3<Float> {
        SIMD3<Float>(Float(-rightMM / 1000), Float((belowTopMM - upperHeightMM / 2) / 1000), frontDistance)
    }

    /// 軸対応が戻せない値（手動で同じ軸を選んだなど）のときは「そのまま」で出す
    private static func unmapped(_ m: SIMD3<Float>, map: HeadTracker.AxisMap) -> SIMD3<Float>? {
        map.inverse(m) ?? HeadTracker.AxisMap.identity.inverse(m)
    }

    private func frontPoint(belowTopMM: Double, rightMM: Double, map: HeadTracker.AxisMap,
                            tracker: HeadTracker, extraFlip: Bool) -> CGPoint? {
        let goal = Self.frontGoal(belowTopMM: belowTopMM, rightMM: rightMM, upperHeightMM: upperHeightMM)
        guard let s = Self.unmapped(goal, map: map) else { return nil }
        return tracker.projectForCalibration(s, extraFlip: extraFlip)
    }

    /// オフセットを動かすと目標が映像の上で動くので、その分を打ち消して枠を画面の同じ場所に保つ量
    private func offsetShift(map: HeadTracker.AxisMap, tracker: HeadTracker, extraFlip: Bool) -> CGSize {
        guard let base = frontPoint(belowTopMM: shiftBaseBelowMM, rightMM: shiftBaseRightMM,
                                    map: map, tracker: tracker, extraFlip: extraFlip),
              let now = frontPoint(belowTopMM: belowTopMM, rightMM: rightMM,
                                   map: map, tracker: tracker, extraFlip: extraFlip) else { return .zero }
        return CGSize(width: base.x - now.x, height: base.y - now.y)
    }

    private func moved(_ p: CGPoint?, by s: CGSize) -> CGPoint? {
        p.map { CGPoint(x: $0.x + s.width, y: $0.y + s.height) }
    }

    private func updateGuide(map: HeadTracker.AxisMap, tracker: HeadTracker) {
        videoShift = offsetShift(map: map, tracker: tracker, extraFlip: false)
        let shift = offsetShift(map: map, tracker: tracker, extraFlip: overlayFlip)
        guard var g = makeGuide(goal: target(upperHeightMM: upperHeightMM), map: map, tracker: tracker) else {
            guide = nil
            return
        }
        g.center = moved(g.center, by: shift) ?? g.center
        g.leftEye = moved(g.leftEye, by: shift) ?? g.leftEye
        g.rightEye = moved(g.rightEye, by: shift) ?? g.rightEye
        guide = g
    }

    /// 矢印の向きへ映像と水色の点が動くように、カメラのオフセットを 0.5mm 動かす。
    /// 向きと軸対応で画面との関係が変わるので、実際に投影して、効きが最も大きい軸を選ぶ
    func nudgeOffset(screenRight: Double, screenDown: Double, tracker: HeadTracker) {
        let map = tracker.axisMap
        guard let p = frontPoint(belowTopMM: belowTopMM, rightMM: rightMM, map: map, tracker: tracker, extraFlip: false),
              let pr = frontPoint(belowTopMM: belowTopMM, rightMM: rightMM + 1, map: map, tracker: tracker, extraFlip: false),
              let pb = frontPoint(belowTopMM: belowTopMM + 1, rightMM: rightMM, map: map, tracker: tracker, extraFlip: false)
        else { return }
        // オフセットを +1mm すると目標がこれだけ動き、映像と点は目標に対して逆へ動く
        let byRight = -(Double(pr.x - p.x) * screenRight + Double(pr.y - p.y) * screenDown)
        let byBelow = -(Double(pb.x - p.x) * screenRight + Double(pb.y - p.y) * screenDown)
        let step = CalibrationNudgePad.stepMM
        if abs(byRight) >= abs(byBelow) {
            rightMM += byRight >= 0 ? step : -step
        } else {
            belowTopMM = max(belowTopMM + (byBelow >= 0 ? step : -step), 0)
        }
        updateGuide(map: map, tracker: tracker)
    }

    var offsetChanged: Bool { belowTopMM != committedBelowMM || rightMM != committedRightMM }

    /// 合った状態で決定する。オフセットを動かしていたら true（画面側が手で合わせた値として保存する）
    func decideFront() -> Bool {
        guard stage == .front, canDecideFront else { return false }
        let changed = offsetChanged
        committedBelowMM = belowTopMM
        committedRightMM = rightMM
        takeBase()
        return changed
    }

    private func makeGuide(goal: SIMD3<Float>, map: HeadTracker.AxisMap, tracker: HeadTracker) -> FaceGuide? {
        let half = SIMD3<Float>(Self.eyeSpacing / 2, 0, 0)
        guard let ls = Self.unmapped(goal - half, map: map), let rs = Self.unmapped(goal + half, map: map),
              var l = tracker.projectForCalibration(ls, extraFlip: overlayFlip),
              var r = tracker.projectForCalibration(rs, extraFlip: overlayFlip) else { return nil }
        // 鏡写しでは左右が入れ替わるので、画面の左にある方を左の目印にする
        if l.x > r.x { swap(&l, &r) }
        let spacing = hypot(r.x - l.x, r.y - l.y)
        guard spacing > 1 else { return nil }
        let perMeter = spacing / CGFloat(Self.eyeSpacing)
        let angle = atan2(r.y - l.y, r.x - l.x)
        let mid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
        let below = Self.faceCenterBelowEyes * perMeter
        return FaceGuide(center: CGPoint(x: mid.x - sin(angle) * below, y: mid.y + cos(angle) * below),
                         size: CGSize(width: Self.faceWidth * perMeter, height: Self.faceHeight * perMeter),
                         leftEye: l, rightEye: r, angle: Double(angle))
    }

    func tick(sample: CalibrationFeed.Sample?, tracker: HeadTracker, upperHeightMM: Double) {
        let map = tracker.axisMap
        self.upperHeightMM = upperHeightMM
        let goal = target(upperHeightMM: upperHeightMM)
        updateGuide(map: map, tracker: tracker)
        let overlayShift = offsetShift(map: map, tracker: tracker, extraFlip: overlayFlip)

        guard let sample else {
            detectedLeft = nil
            detectedRight = nil
            frameState = .noFace
            canUseAsBase = false
            canDecideFront = false
            matchedSince = nil
            window.removeAll()
            instruction = "枠の中に顔を入れてください"
            return
        }
        let left = moved(tracker.projectForCalibration(sample.leftEye, extraFlip: overlayFlip), by: overlayShift)
        let right = moved(tracker.projectForCalibration(sample.rightEye, extraFlip: overlayFlip), by: overlayShift)
        detectedLeft = left
        detectedRight = right

        // 傾きは見えている映像の上で測る（軸対応がまだ違っていても正しく出る）
        var tilted = false
        if let left, let right {
            let degrees = atan2(abs(Double(right.y - left.y)), abs(Double(right.x - left.x))) * 180 / .pi
            tilted = degrees >= Self.tiltLimitDegrees
        }

        let isReturn = stage == .backFromRight || stage == .backFromUp
        // 正面へ戻る段は軸対応に左右されないよう、基準の位置との距離で見る
        let current = isReturn ? sample.screen : map.apply(sample.screen)
        let aim = isReturn ? baseScreen : goal
        let diff = aim - current
        let onTarget: Bool
        if isReturn {
            onTarget = simd_length(diff) <= Self.returnRadius
        } else {
            onTarget = hypot(diff.x, diff.y) <= Self.matchRadius && abs(diff.z) <= Self.matchDistance
        }
        let matched = onTarget && !tilted
        frameState = matched ? .matched : .off
        if tilted {
            instruction = "顔をまっすぐにしてください"
        } else if matched {
            instruction = stage == .verify ? "合っています" : "そのまま止まってください"
        } else if stage == .front, abs(diff.z) <= Self.matchDistance {
            instruction = "顔は動かさず、ボタンで合わせてください"
        } else {
            instruction = Self.guidance(mirrorGuidanceDelta(aim: isReturn ? baseScreen : Self.unmapped(goal, map: map),
                                                            current: sample.screen, fallback: diff, tracker: tracker))
        }

        window.append(sample)
        let hold = stage == .front ? Self.frontHold : Self.stepHold
        window.removeAll { sample.time - $0.time > hold }
        let filled = (window.first.map { sample.time - $0.time } ?? 0) >= hold * 0.9
        let mean = window.reduce(SIMD3<Float>.zero) { $0 + $1.screen } / Float(max(window.count, 1))
        let still = filled && window.allSatisfy { simd_length($0.screen - mean) <= Self.stillRadius }

        if matched {
            if matchedSince == nil { matchedSince = sample.time }
        } else {
            matchedSince = nil
        }
        let heldOnTarget = still && (matchedSince.map { sample.time - $0 >= hold * 0.9 } ?? false)

        switch stage {
        case .front:
            canUseAsBase = still && Self.frontRange.contains(mean.z)
            canDecideFront = heldOnTarget && canUseAsBase
        case .right, .up, .near:
            canUseAsBase = false
            let delta = mean - baseScreen
            let moved = max(abs(delta.x), abs(delta.y), abs(delta.z))
            if still && (heldOnTarget || moved >= Self.recordMove) { recordStep(delta: delta, moved: moved) }
        case .backFromRight:
            if heldOnTarget { advance(to: .up) }
        case .backFromUp:
            if heldOnTarget { advance(to: .near) }
        case .verify:
            canUseAsBase = false
        }
    }

    /// 鏡映しの画面の上で、目標と今の位置の差を取る（x 右、y 上、z 距離、単位 m）。
    /// 画面で右にある目標へは、体を右へ動かせば近づく
    private func mirrorGuidanceDelta(aim: SIMD3<Float>?, current: SIMD3<Float>, fallback: SIMD3<Float>,
                                     tracker: HeadTracker) -> SIMD3<Float> {
        guard let aim, let g = guide,
              let a = tracker.projectForCalibration(aim),
              let c = tracker.projectForCalibration(current) else { return fallback }
        let spacing = hypot(g.rightEye.x - g.leftEye.x, g.rightEye.y - g.leftEye.y)
        guard spacing > 1 else { return fallback }
        let metersPerPt = CGFloat(Self.eyeSpacing) / spacing
        return SIMD3<Float>(Float((a.x - c.x) * metersPerPt), Float((c.y - a.y) * metersPerPt), fallback.z)
    }

    /// 「保存せず基準にする」：軸がまだ違うと正面の目印に合わせられないので、距離が合って止まっていれば進める。
    /// 動かしたオフセットは保存した値へ戻す
    func recordBase() {
        guard stage == .front, !window.isEmpty else { return }
        belowTopMM = committedBelowMM
        rightMM = committedRightMM
        takeBase()
    }

    private func takeBase() {
        guard !window.isEmpty else { return }
        baseScreen = window.reduce(SIMD3<Float>.zero) { $0 + $1.screen } / Float(window.count)
        baseCamera = window.reduce(SIMD3<Float>.zero) { $0 + $1.camera } / Float(window.count)
        message = ""
        advance(to: .right)
    }

    private func recordStep(delta: SIMD3<Float>, moved: Float) {
        guard moved >= Self.minimumMove else {
            message = "動きが 4cm 未満でした。この段をやり直します"
            window.removeAll()
            matchedSince = nil
            return
        }
        let axis = Self.dominantAxis(delta)
        let sign: Float = delta[axis] < 0 ? -1 : 1
        let cameraMean = window.reduce(SIMD3<Float>.zero) { $0 + $1.camera } / Float(window.count)
        let cameraDelta = cameraMean - baseCamera
        let cameraAxis = Self.dominantAxis(cameraDelta)
        let cameraLabel = "\(cameraDelta[cameraAxis] < 0 ? "−" : "+")\(["x", "y", "z"][cameraAxis])"
        message = ""
        switch stage {
        case .right:
            guard axis != 2 else { restart("右の動きが奥行きの軸に出ました。最初からやり直します"); return }
            rightMove = (axis: axis, sign: sign, camera: cameraLabel)
            advance(to: .backFromRight)
        case .up:
            guard axis != 2, axis != rightMove?.axis else { restart("右と上で同じ軸が選ばれました。最初からやり直します"); return }
            upMove = (axis: axis, sign: sign, camera: cameraLabel)
            advance(to: .backFromUp)
        case .near:
            guard axis == 2, delta.z < 0 else { restart("近づく動きが距離の軸に出ませんでした。最初からやり直します"); return }
            finish(nearCamera: cameraLabel)
        case .front, .backFromRight, .backFromUp, .verify:
            break
        }
    }

    private func finish(nearCamera: String) {
        guard let r = rightMove, let u = upMove else { restart("記録が足りません。最初からやり直します"); return }
        let map = HeadTracker.AxisMap(xAxis: r.axis, xSign: r.sign, yAxis: u.axis, ySign: u.sign)
        let names = HeadTracker.AxisMap.labels
        let text = "画面の右＝カメラの \(r.camera)（画面座標の \(names[HeadTracker.AxisMap.code(axis: r.axis, sign: r.sign)])）\n"
            + "画面の上＝カメラの \(u.camera)（画面座標の \(names[HeadTracker.AxisMap.code(axis: u.axis, sign: u.sign)])）\n"
            + "近づく＝カメラの \(nearCamera)"
        pendingMap = map
        resultText = text
        advance(to: .verify)
    }

    /// 計測した軸対応（保存は画面側が tracker へ渡して行う）
    private(set) var pendingMap: HeadTracker.AxisMap?

    func restart(_ reason: String = "") {
        rightMove = nil
        upMove = nil
        pendingMap = nil
        resultText = nil
        advance(to: .front)
        message = reason
    }

    func setFlip(_ v: Bool) {
        overlayFlip = v
        HologramCalibrationStore.saveOverlayFlip(v, machineID: machineID)
    }

    private func advance(to next: Stage) {
        stage = next
        window.removeAll()
        matchedSince = nil
        frameState = .off
        canUseAsBase = false
        canDecideFront = false
    }

    private static func dominantAxis(_ v: SIMD3<Float>) -> Int {
        var best = 0
        for i in 1..<3 where abs(v[i]) > abs(v[best]) { best = i }
        return best
    }

    /// いちばん大きいずれを1つだけ案内する。d は 目標 − 現在（x 右、y 上、z 距離）
    private static func guidance(_ d: SIMD3<Float>) -> String {
        if abs(d.z) >= abs(d.x), abs(d.z) >= abs(d.y) {
            return d.z < 0 ? "もう少し近づいて" : "もう少し離れて"
        }
        if abs(d.x) >= abs(d.y) { return d.x >= 0 ? "もう少し右へ" : "もう少し左へ" }
        return d.y >= 0 ? "もう少し上へ" : "もう少し下へ"
    }
}

/// G3：本人確認の顔撮影の形で、インカメの映像を見ながら軸の向きを測る画面。
struct HologramAxisCalibrationView: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onNext: () -> Void
    var onFinish: () -> Void

    @StateObject private var feed = CalibrationFeed()
    @StateObject private var model: AxisCalibrationModel
    @State private var showDeveloper = false

    init(tracker: HeadTracker, diagnostics: HologramDiagnostics,
         onNext: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.tracker = tracker
        self.diagnostics = diagnostics
        self.onNext = onNext
        self.onFinish = onFinish
        let p = diagnostics.cameraProfile
        _model = StateObject(wrappedValue: AxisCalibrationModel(belowTopMM: p.cameraBelowTopMM, rightMM: p.cameraRightMM))
    }

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            let upper = CGSize(width: geo.size.width, height: fold)
            ZStack(alignment: .topLeading) {
                Color.black
                videoLayer(size: upper)
                    .frame(width: upper.width, height: upper.height)
                    .clipped()
                controls
                    .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
                    .offset(y: fold)
            }
            .onAppear { tracker.setCalibrationFeed(feed, viewport: upper) }
            .onChange(of: upper) { _, size in tracker.setCalibrationFeed(feed, viewport: size) }
            .onReceive(feed.$sample) { sample in
                model.tick(sample: sample, tracker: tracker, upperHeightMM: Double(fold) * HologramDeviceProfile.mmPerPoint)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onDisappear { tracker.setCalibrationFeed(nil, viewport: .zero) }
        .onChange(of: model.frameState) { _, state in
            if state == .matched { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        .onChange(of: model.stage) { _, stage in
            guard stage == .verify, let map = model.pendingMap, let text = model.resultText else { return }
            tracker.setAxisMap(map)
            HologramCalibrationStore.saveMeasured(map, resultText: text, machineID: HologramDeviceProfile.readMachineID())
            diagnostics.isCalibrated = true
            diagnostics.calibrationResult = text
        }
    }

    private var frameColor: Color {
        switch model.frameState {
        case .noFace: return .white
        case .off: return .yellow
        case .matched: return .green
        }
    }

    private func videoLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(model.videoShift)
            }
            if let g = model.guide {
                faceGuide(g, size: size)
                    .animation(.easeInOut(duration: 0.45), value: model.stage)
            }
            detectedEye(model.detectedLeft)
            detectedEye(model.detectedRight)
            VStack(spacing: 6) {
                progressDots
                Text(model.instruction)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .padding(.top, 8)
            .frame(width: size.width)
            trackingStatus
                .frame(width: size.width, height: size.height, alignment: .bottomTrailing)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// 枠の外を暗くし、顔の枠と目の目印を描く
    private func faceGuide(_ g: AxisCalibrationModel.FaceGuide, size: CGSize) -> some View {
        let spacing = hypot(g.rightEye.x - g.leftEye.x, g.rightEye.y - g.leftEye.y)
        let mid = CGPoint(x: (g.leftEye.x + g.rightEye.x) / 2, y: (g.leftEye.y + g.rightEye.y) / 2)
        let dash: [CGFloat] = model.frameState == .noFace ? [8, 6] : []
        return ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.55)
                Ellipse()
                    .frame(width: g.size.width, height: g.size.height)
                    .rotationEffect(.radians(g.angle))
                    .position(g.center)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: size.width, height: size.height)

            Ellipse()
                .stroke(frameColor, style: StrokeStyle(lineWidth: 3, dash: dash))
                .frame(width: g.size.width, height: g.size.height)
                .rotationEffect(.radians(g.angle))
                .position(g.center)
            Rectangle()
                .fill(frameColor.opacity(0.8))
                .frame(width: spacing, height: 1)
                .rotationEffect(.radians(g.angle))
                .position(mid)
            eyeMark.position(g.leftEye)
            eyeMark.position(g.rightEye)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 目標の目印：枠と同じ色の輪
    private var eyeMark: some View {
        Circle().stroke(frameColor, lineWidth: 2).frame(width: 14, height: 14)
    }

    /// ARKit が見つけた目：水色のひし形（目標の輪と区別する）
    @ViewBuilder private func detectedEye(_ point: CGPoint?) -> some View {
        if let point {
            Rectangle()
                .fill(.cyan)
                .frame(width: 6, height: 6)
                .rotationEffect(.degrees(45))
                .position(point)
                .allowsHitTesting(false)
        }
    }

    /// 進み具合（正面・右・上・近づく）。済んだ段は緑
    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < model.completedSteps ? Color.green : Color.white.opacity(0.35))
                    .frame(width: 10, height: 10)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("4段のうち \(model.completedSteps) 段済み")
    }

    /// 顔が見つからない原因の切り分け：追跡状態、アンカー数、顔アンカーの isTracked
    private var trackingStatus: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let d = tracker.diagnosticsSnapshot()
            let tracked = d.lastFaceTracked.map { $0 ? "true" : "false" } ?? "顔アンカーなし"
            Text("追跡 \(d.cameraState)\nアンカー \(d.lastAnchorCount)（顔 \(d.lastFaceAnchorCount)）\nisTracked \(tracked)\n映像の向き \(tracker.videoTurns * 90)°")
                .font(.system(size: 9, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .padding(4)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(model.title).font(.headline).multilineTextAlignment(.center)
                if !model.message.isEmpty {
                    Text(model.message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if let result = model.resultText {
                    Text(result).font(.system(.footnote, design: .monospaced)).multilineTextAlignment(.center)
                }
                if model.stage == .front {
                    Text("端末の正面を向いているのに目が目印に合わないときは、カメラ位置のずれです。顔は動かさず、そのまま正面を向いて、矢印で映像と水色の点を目印へ動かしてください")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    if !diagnostics.isCalibrated {
                        Text("軸の計測がまだのときは、矢印の値が正しくならないことがあります。合わないときは「保存せず基準にする」で先へ進んでください")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }
                    Text(HologramDeviceProfile.cameraPositionText(belowTopMM: model.belowTopMM, rightMM: model.rightMM))
                        .font(.system(.caption, design: .monospaced))
                        .multilineTextAlignment(.center)
                    CalibrationNudgePad { right, down in
                        model.nudgeOffset(screenRight: right, screenDown: down, tracker: tracker)
                    }
                    Button("決定", action: decideFront)
                        .bold()
                        .disabled(!model.canDecideFront)
                }
                HStack(spacing: 18) {
                    if model.stage == .front {
                        Button("保存せず基準にする") { model.recordBase() }
                            .disabled(!model.canUseAsBase)
                    }
                    Button("最初から") { model.restart() }
                    if model.stage == .verify {
                        Button("次へ（箱の確認）", action: onNext).bold()
                    } else {
                        Button("やめる", action: onFinish)
                    }
                }
                .font(.caption)
                DisclosureGroup("開発用", isExpanded: $showDeveloper) {
                    VStack(spacing: 8) {
                        Text(HologramDeviceProfile.cameraPositionText(belowTopMM: model.belowTopMM, rightMM: model.rightMM))
                            .font(.system(.caption, design: .monospaced))
                            .multilineTextAlignment(.center)
                        Button("点だけ追加で左右反転（鏡映しの上から）：\(model.overlayFlip ? "オン" : "オフ")") {
                            model.setFlip(!model.overlayFlip)
                        }
                        .font(.caption)
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(12)
        }
    }

    private func decideFront() {
        guard model.decideFront() else { return }
        diagnostics.saveManualCamera(belowTopMM: model.belowTopMM, rightMM: model.rightMM)
    }
}
