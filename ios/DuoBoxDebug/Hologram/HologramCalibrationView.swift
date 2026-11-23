import SwiftUI

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

/// G2：アプリが思っているカメラの位置に輪を出し、実物のカメラの点へ合わせる画面。
struct HologramCameraAlignView: View {
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
                Color.clear
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
        .onAppear(perform: loadCurrent)
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("画面を斜めから見ると、カメラの点が見えます。輪をその点に合わせてください")
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

/// G2 → G3 を通しで進める画面。
struct HologramCalibrationFlow: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onClose: () -> Void

    private enum Step { case camera, axis, box }
    @State private var step = Step.camera

    var body: some View {
        switch step {
        case .camera:
            HologramCameraAlignView(diagnostics: diagnostics,
                                    onDecide: { step = .axis },
                                    onCancel: onClose)
        case .axis:
            HologramAxisCalibrationView(tracker: tracker, diagnostics: diagnostics,
                                        onNext: { step = .box }, onFinish: onClose)
        case .box:
            HologramBoxCheckView(diagnostics: diagnostics,
                                 onRetry: { step = .camera }, onFinish: onClose)
        }
    }
}

/// G4：画面の奥 30mm の格子の箱で、最後の確認をする。上パネルは絵を見せるため何も重ねない。
struct HologramBoxCheckView: View {
    @ObservedObject var diagnostics: HologramDiagnostics
    var onRetry: () -> Void
    var onFinish: () -> Void
    @State private var answeredNo = false

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            ScrollView {
                VStack(spacing: 12) {
                    if answeredNo {
                        Text("カメラ位置と軸の向きを、もう一度合わせてください")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 24) {
                            Button("閉じる", action: onFinish)
                            Button("カメラ位置からやり直す", action: onRetry).bold()
                        }
                    } else {
                        Text("片目を閉じて、頭をゆっくり左右に動かしてください。箱が画面の奥に止まって見えますか")
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 32) {
                            Button("いいえ") { answer(false) }
                            Button("はい") { answer(true) }.bold()
                        }
                        .font(.title3)
                    }
                }
                .padding(14)
            }
            .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
            .background(Color.black)
            .offset(y: fold)
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear { diagnostics.rig?.setCheckMode(true) }
        .onDisappear { diagnostics.rig?.setCheckMode(false) }
    }

    private func answer(_ yes: Bool) {
        HologramCalibrationStore.saveBoxCheck(yes, machineID: HologramDeviceProfile.readMachineID())
        diagnostics.boxCheck = yes
        if yes { onFinish() } else { answeredNo = true }
    }
}

/// G3 の進行と判定。座標はすべて「カメラから見た目の位置」で扱う。
final class AxisCalibrationModel: ObservableObject {
    enum Stage: Int { case front, right, up, near, verify }

    static let frontDistance: Float = 0.35       // 正面の目標の距離（m）
    static let frontRange: ClosedRange<Float> = 0.30...0.40
    static let stepDistance: Float = 0.10        // 右・上・近づくの目標の移動量（m）
    static let recordMove: Float = 0.08          // 輪に入らなくても記録する移動量（m）
    static let minimumMove: Float = 0.04         // これ未満はやり直し（m）
    static let stillRadius: Float = 0.012        // 止まっているとみなす揺れ（m）
    static let returnRadius: Float = 0.03        // 次の段を始める前に正面へ戻ったとみなす距離（m）
    static let frontHold: TimeInterval = 2
    static let stepHold: TimeInterval = 1
    static let ringRadius: CGFloat = 34

    @Published private(set) var stage = Stage.front
    @Published private(set) var message = ""
    @Published private(set) var remaining = ""
    @Published private(set) var eyePoint: CGPoint?
    @Published private(set) var ringPoint: CGPoint?
    @Published private(set) var ringScale: CGFloat = 1
    @Published private(set) var inRing = false
    @Published private(set) var canUseAsBase = false
    @Published private(set) var resultText: String?
    @Published var belowTopMM: Double
    @Published var rightMM: Double
    @Published var overlayFlip: Bool

    private let machineID = HologramDeviceProfile.readMachineID()
    private var window: [CalibrationFeed.Sample] = []
    private var baseScreen = SIMD3<Float>.zero
    private var baseCamera = SIMD3<Float>.zero
    private var rightMove: (axis: Int, sign: Float, camera: String)?
    private var upMove: (axis: Int, sign: Float, camera: String)?
    /// 前の段の位置のまま次の段を記録しないよう、正面へ戻るまで計測を始めない
    private var armed = true

    init(belowTopMM: Double, rightMM: Double) {
        self.belowTopMM = belowTopMM
        self.rightMM = rightMM
        overlayFlip = HologramCalibrationStore.overlayFlip(machineID: HologramDeviceProfile.readMachineID())
    }

    var title: String {
        switch stage {
        case .front: return "1/4 正面：端末の正面に顔を置いてください。点が輪に入っていれば、カメラのずれは合っています"
        case .right: return "2/4 右：顔を右へ 10cm 動かして止めてください"
        case .up: return "3/4 上：正面に戻ってから、顔を上へ 10cm 動かして止めてください"
        case .near: return "4/4 近づく：正面に戻ってから、10cm 近づいて止めてください"
        case .verify: return "確認：端末の正面に顔を置くと、点が輪に入りますか"
        }
    }

    var arrowText: String {
        switch stage {
        case .front, .verify: return "正面"
        case .right: return "→ 右へ"
        case .up: return "↑ 上へ"
        case .near: return "近づく"
        }
    }

    /// いまの段の目標（カメラから見た位置、軸対応後の座標）
    private func target(upperHeightMM: Double) -> SIMD3<Float> {
        // 上パネル中央の正面 − カメラ位置
        var t = SIMD3<Float>(Float(-rightMM / 1000), Float((belowTopMM - upperHeightMM / 2) / 1000), Self.frontDistance)
        switch stage {
        case .right: t.x += Self.stepDistance
        case .up: t.y += Self.stepDistance
        case .near: t.z -= Self.stepDistance
        case .front, .verify: break
        }
        return t
    }

    func tick(sample: CalibrationFeed.Sample?, tracker: HeadTracker, upperHeightMM: Double) {
        let map = tracker.axisMap
        let goal = target(upperHeightMM: upperHeightMM)
        // 軸対応が戻せない値（手動で同じ軸を選んだなど）のときは「そのまま」で輪を出す
        let goalScreen = map.inverse(goal) ?? HeadTracker.AxisMap.identity.inverse(goal)
        ringPoint = goalScreen.flatMap { tracker.projectForCalibration($0, flip: overlayFlip) }
        ringScale = CGFloat(Self.frontDistance / max(goal.z, 0.05))

        guard let sample else {
            eyePoint = nil
            inRing = false
            canUseAsBase = false
            window.removeAll()
            remaining = "顔が見つかりません"
            return
        }
        eyePoint = tracker.projectForCalibration(sample.screen, flip: overlayFlip)
        let radius = Self.ringRadius * ringScale
        var entered = false
        if let e = eyePoint, let r = ringPoint { entered = hypot(e.x - r.x, e.y - r.y) <= radius }
        if stage == .near { entered = entered && abs(sample.screen.z - goal.z) <= 0.02 }
        inRing = entered
        remaining = guidance(current: map.apply(sample.screen), goal: goal)

        if !armed {
            let away = simd_length(sample.screen - baseScreen)
            guard away <= Self.returnRadius else {
                remaining = "いったん正面へ戻ってください（あと \(Self.cm(away - Self.returnRadius))cm）"
                inRing = false
                window.removeAll()
                return
            }
            armed = true
            window.removeAll()
        }

        window.append(sample)
        let hold = stage == .front ? Self.frontHold : Self.stepHold
        window.removeAll { sample.time - $0.time > hold }
        let filled = (window.first.map { sample.time - $0.time } ?? 0) >= hold * 0.9
        let mean = window.reduce(SIMD3<Float>.zero) { $0 + $1.screen } / Float(max(window.count, 1))
        let still = filled && window.allSatisfy { simd_length($0.screen - mean) <= Self.stillRadius }

        switch stage {
        case .front:
            let okDistance = Self.frontRange.contains(mean.z)
            canUseAsBase = still && okDistance
            if canUseAsBase && entered { recordBase() }
        case .right, .up, .near:
            canUseAsBase = false
            let delta = mean - baseScreen
            let moved = max(abs(delta.x), abs(delta.y), abs(delta.z))
            if still && (entered || moved >= Self.recordMove) { recordStep(delta: delta, moved: moved) }
        case .verify:
            canUseAsBase = false
        }
    }

    /// 「このまま基準にする」：軸がまだ違うと正面の輪に入れないので、距離が合って止まっていれば進める
    func recordBase() {
        guard stage == .front, !window.isEmpty else { return }
        baseScreen = window.reduce(SIMD3<Float>.zero) { $0 + $1.screen } / Float(window.count)
        baseCamera = window.reduce(SIMD3<Float>.zero) { $0 + $1.camera } / Float(window.count)
        message = ""
        advance(to: .right)
    }

    private func recordStep(delta: SIMD3<Float>, moved: Float) {
        guard moved >= Self.minimumMove else {
            message = "動きが 4cm 未満でした。この段をやり直します"
            window.removeAll()
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
            advance(to: .up)
        case .up:
            guard axis != 2, axis != rightMove?.axis else { restart("右と上で同じ軸が選ばれました。最初からやり直します"); return }
            upMove = (axis: axis, sign: sign, camera: cameraLabel)
            advance(to: .near)
        case .near:
            guard axis == 2, delta.z < 0 else { restart("近づく動きが距離の軸に出ませんでした。最初からやり直します"); return }
            finish(nearCamera: cameraLabel)
        case .front, .verify:
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
        armed = !(next == .up || next == .near)
        window.removeAll()
        canUseAsBase = false
    }

    private static func dominantAxis(_ v: SIMD3<Float>) -> Int {
        var best = 0
        for i in 1..<3 where abs(v[i]) > abs(v[best]) { best = i }
        return best
    }

    private func guidance(current c: SIMD3<Float>, goal g: SIMD3<Float>) -> String {
        if stage == .front || stage == .verify {
            if c.z < Self.frontRange.lowerBound { return "もう少し離れて（あと \(Self.cm(Self.frontRange.lowerBound - c.z))cm）" }
            if c.z > Self.frontRange.upperBound { return "もう少し近づいて（あと \(Self.cm(c.z - Self.frontRange.upperBound))cm）" }
        }
        if stage == .near { return g.z < c.z ? "近づいて あと \(Self.cm(c.z - g.z))cm" : "離れて あと \(Self.cm(g.z - c.z))cm" }
        let d = g - c
        if abs(d.x) >= abs(d.y) { return "\(d.x >= 0 ? "右" : "左")へ あと \(Self.cm(abs(d.x)))cm" }
        return "\(d.y >= 0 ? "上" : "下")へ あと \(Self.cm(abs(d.y)))cm"
    }

    private static func cm(_ m: Float) -> String { String(format: "%.1f", m * 100) }
}

/// G3：インカメの映像を見ながら軸の向きを測る画面。
struct HologramAxisCalibrationView: View {
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onNext: () -> Void
    var onFinish: () -> Void

    @StateObject private var feed = CalibrationFeed()
    @StateObject private var model: AxisCalibrationModel

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
        .onChange(of: model.stage) { _, stage in
            guard stage == .verify, let map = model.pendingMap, let text = model.resultText else { return }
            tracker.setAxisMap(map)
            HologramCalibrationStore.saveMeasured(map, resultText: text, machineID: HologramDeviceProfile.readMachineID())
            diagnostics.isCalibrated = true
            diagnostics.calibrationResult = text
        }
    }

    private func videoLayer(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            if let image = feed.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .frame(width: size.width, height: size.height)
            }
            if let r = model.ringPoint {
                let d = AxisCalibrationModel.ringRadius * model.ringScale * 2
                Circle()
                    .strokeBorder(model.inRing ? .green : .yellow, lineWidth: 3)
                    .frame(width: d, height: d)
                    .position(r)
                Text(model.arrowText)
                    .font(.caption.bold())
                    .padding(4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .position(x: r.x, y: max(r.y - d / 2 - 14, 12))
            }
            if let e = model.eyePoint {
                Circle().fill(.cyan).frame(width: 10, height: 10).position(e)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(model.title).font(.headline).multilineTextAlignment(.center)
                Text(model.remaining).font(.title2.bold()).monospacedDigit()
                if !model.message.isEmpty {
                    Text(model.message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                }
                if let result = model.resultText {
                    Text(result).font(.system(.footnote, design: .monospaced)).multilineTextAlignment(.center)
                }
                Text(HologramDeviceProfile.cameraPositionText(belowTopMM: model.belowTopMM, rightMM: model.rightMM))
                    .font(.system(.caption, design: .monospaced))
                    .multilineTextAlignment(.center)
                CalibrationNudgePad { right, down in
                    model.rightMM += right
                    model.belowTopMM = max(model.belowTopMM + down, 0)
                }
                HStack(spacing: 14) {
                    Button("カメラ位置を決定") {
                        diagnostics.saveManualCamera(belowTopMM: model.belowTopMM, rightMM: model.rightMM)
                    }
                    Button("点の左右を反転") { model.setFlip(!model.overlayFlip) }
                }
                .font(.caption)
                HStack(spacing: 18) {
                    if model.stage == .front {
                        Button("このまま基準にする") { model.recordBase() }
                            .disabled(!model.canUseAsBase)
                    }
                    Button("最初から") { model.restart() }
                    if model.stage == .verify {
                        Button("次へ（箱の確認）", action: onNext).bold()
                    } else {
                        Button("やめる", action: onFinish).bold()
                    }
                }
                .font(.callout)
            }
            .padding(12)
        }
    }
}
