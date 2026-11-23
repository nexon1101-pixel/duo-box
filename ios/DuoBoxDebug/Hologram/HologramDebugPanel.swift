import QuartzCore
import SceneKit
import SwiftUI

/// 計測パネルへ渡す、画面（コンテナ）側で分かる値。
final class HologramDiagnostics: ObservableObject {
    /// 配置・描画の現在値を読むための参照（パネルが定期的に読む）
    weak var rig: HologramRig?
    /// 調整値：壁を奥へ下げる量（mm、初期値 30）と、身長の倍率（検証用、初期値 1）
    @Published var wallRecessMM: Double = 30 { didSet { saveTunes() } }
    @Published var heightScale: Double = 1 { didSet { saveTunes() } }
    /// 前後位置 p：0＝手前の端、1＝折り目、1超＝床の角まで。既定は HologramRig.defaultPPos
    @Published var pPos: Double = Double(HologramRig.defaultPPos) { didSet { saveTunes() } }
    @Published var pAuto: Bool = true { didSet { saveTunes() } }
    @Published var wAuto: Bool = true { didSet { saveTunes() } }
    @Published var wLean: Double = 0 { didSet { saveTunes() } }
    /// 1€ フィルタの調整値（手順5）：最小カットオフ (Hz)、速度係数 β、先読み (ms)
    @Published var oeMinCutoff: Double = 1.2 { didSet { saveTunes() } }
    @Published var oeBeta: Double = 0.8 { didSet { saveTunes() } }
    /// 先読みは 1 つの値。調整値（hologram.tunes.v1）に加えて機種ごとにも保存し、起動時は機種ごとの値を優先する
    @Published var oePredMS: Double = 20 {
        didSet {
            saveTunes()
            guard tunesReady else { return }
            HologramCalibrationStore.savePredictionMS(oePredMS, machineID: machineID)
        }
    }
    /// 距離の倍率（機種ごとに保存）。カメラから見た目の位置の x・y・z に掛ける
    @Published var distanceScale: Double = 1 {
        didSet {
            guard tunesReady else { return }
            HologramCalibrationStore.saveDistanceScale(distanceScale, machineID: machineID)
        }
    }
    /// 実寸計測（パネル①）のクレカの棒の長さ (pt)
    @Published var rulerBarLength: Double = 200 { didSet { saveTunes() } }
    /// 角度ごとの p・w の記録（UserDefaults に保存）
    @Published var pwRecords: [PWRecord] = []

    struct PWRecord: Equatable {
        var angleDeg: Double
        var p: Double
        var w: Double
    }

    private static let pwKey = "hologram.pwTable.v1"
    private static let tunesKey = "hologram.tunes.v1"
    /// init の読み込みが終わるまで保存しない
    private var tunesReady = false
    private let machineID = HologramDeviceProfile.readMachineID()

    init() {
        let raw = UserDefaults.standard.array(forKey: Self.pwKey) as? [[Double]] ?? []
        pwRecords = raw.compactMap { $0.count == 3 ? PWRecord(angleDeg: $0[0], p: $0[1], w: $0[2]) : nil }
            .sorted { $0.angleDeg < $1.angleDeg }

        // 無い項目・壊れた項目は、プロパティの初期値のままにする
        let t = UserDefaults.standard.dictionary(forKey: Self.tunesKey) ?? [:]
        func number(_ key: String) -> Double? {
            guard let v = t[key] as? Double, v.isFinite else { return nil }
            return v
        }
        if let v = number("wallRecessMM") { wallRecessMM = v }
        if let v = number("heightScale") { heightScale = v }
        if let v = number("pPos") { pPos = v }
        if let v = t["pAuto"] as? Bool { pAuto = v }
        if let v = t["wAuto"] as? Bool { wAuto = v }
        if let v = number("wLean") { wLean = v }
        if let v = number("oeMinCutoff") { oeMinCutoff = v }
        if let v = number("oeBeta") { oeBeta = v }
        if let v = number("oePredMS") { oePredMS = min(max(v, 0), 120) }
        if let v = HologramCalibrationStore.predictionMS(machineID: machineID) { oePredMS = v }
        distanceScale = HologramCalibrationStore.distanceScale(machineID: machineID)
        if let v = number("rulerBarLength") { rulerBarLength = v }
        if let v = t["showMarkers"] as? Bool { showMarkers = v }
        if let v = t["showGrid"] as? Bool { showGrid = v }
        tunesReady = true
    }

    /// 調整値をまとめて保存する（値が変わるたびに呼ばれる）
    private func saveTunes() {
        guard tunesReady else { return }
        let t: [String: Any] = [
            "wallRecessMM": wallRecessMM,
            "heightScale": heightScale,
            "pPos": pPos,
            "pAuto": pAuto,
            "wAuto": wAuto,
            "wLean": wLean,
            "oeMinCutoff": oeMinCutoff,
            "oeBeta": oeBeta,
            "oePredMS": oePredMS,
            "rulerBarLength": rulerBarLength,
            "showMarkers": showMarkers,
            "showGrid": showGrid,
        ]
        UserDefaults.standard.set(t, forKey: Self.tunesKey)
    }

    /// いまの角度・p・w を記録する（同じ角度（±1°以内）の記録があれば置き換え）
    func recordCurrentPW(angleDeg: Double, p: Double, w: Double) {
        pwRecords.removeAll { abs($0.angleDeg - angleDeg) < 1 }
        pwRecords.append(PWRecord(angleDeg: angleDeg, p: p, w: w))
        pwRecords.sort { $0.angleDeg < $1.angleDeg }
        persistPW()
    }

    func deletePWRecord(at index: Int) {
        guard pwRecords.indices.contains(index) else { return }
        pwRecords.remove(at: index)
        persistPW()
    }

    private func persistPW() {
        UserDefaults.standard.set(pwRecords.map { [$0.angleDeg, $0.p, $0.w] }, forKey: Self.pwKey)
    }
    /// 位置合わせマーカーの表示
    @Published var showMarkers = false { didSet { saveTunes() } }
    /// 格子（床と壁）の表示
    @Published var showGrid = true { didSet { saveTunes() } }
    /// 機種プロファイル
    @Published var profileID = ""
    /// 読み取ったカメラ位置を含むプロファイル
    @Published var cameraProfile = HologramDeviceProfile.current()
    @Published var mmPerPt: Double = HologramDeviceProfile.mmPerPoint
    /// 折り目のY位置（reserved regions が取れなければ nil＝画面中央で代用中）
    @Published var foldY: CGFloat?
    @Published var materialFound = 0
    @Published var materialTotal = 0
    /// カメラ位置を変えたときに、描画側へすぐ反映するための入り口（コンテナが設定する）
    var requestLayoutPush: (() -> Void)?
    /// G3 の計測を実施済みか（未実施の表示に使う）
    @Published var isCalibrated = HologramCalibrationStore.isCalibrated(machineID: HologramDeviceProfile.readMachineID())
    @Published var calibrationResult = HologramCalibrationStore.resultText(machineID: HologramDeviceProfile.readMachineID())
    /// G4 の箱の確認の答え（未回答は nil）
    @Published var boxCheck = HologramCalibrationStore.boxCheck(machineID: HologramDeviceProfile.readMachineID())

    /// 調整値を既定に戻す（距離の倍率も 1.00 へ）。軸対応・カメラ位置・角度ごとの記録・クレカの棒（実測値）は消さない
    func resetTunes() {
        wallRecessMM = 30
        heightScale = 1
        pPos = Double(HologramRig.defaultPPos)
        pAuto = true
        wAuto = true
        wLean = 0
        oeMinCutoff = 1.2
        oeBeta = 0.8
        oePredMS = 20
        distanceScale = 1
        showMarkers = false
        showGrid = true
    }

    /// 映像の向きを決める。向きが変わったら前の軸対応の結果は無効なので、表示も未実施へ戻す
    func chooseVideoTurns(_ turns: Int, tracker: HeadTracker) {
        guard tracker.setVideoTurns(turns) else { return }
        isCalibrated = false
        calibrationResult = nil
        boxCheck = nil
    }

    /// 手で合わせたカメラ位置を機種IDごとに保存し、すぐ反映する
    func saveManualCamera(belowTopMM: Double, rightMM: Double) {
        HologramCalibrationStore.saveManualCamera(.init(belowTopMM: belowTopMM, rightMM: rightMM),
                                                  machineID: HologramDeviceProfile.readMachineID())
        requestLayoutPush?()
    }

    /// 手で合わせた値を消して、occlusion の値へ戻す
    func clearManualCamera() {
        HologramCalibrationStore.clearManualCamera(machineID: HologramDeviceProfile.readMachineID())
        requestLayoutPush?()
    }
}

/// 三本指タップで開閉するデバッグパネル。実寸計測・端末情報・シェーダ書式チップ。
struct HologramDebugPanel: View {
    @ObservedObject var hinge: HingeMonitor
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onCalibrate: () -> Void
    var onCompare: () -> Void
    /// L 字の確認の箱が開いているか、と開閉
    var isLBoxOpen: Bool
    var onToggleLBox: () -> Void
    var onClose: () -> Void

    /// クレジットカード（ISO/IEC 7810 ID-1）の長辺
    private static let cardLongSideMM: Double = 85.60
    /// 設定をコピーした時刻（「コピーしました」を少しの間出す）
    @State private var copiedAt: Date?
    @State private var confirmReset = false
    /// 開発用：カメラ位置の手動入力
    @State private var devBelowText = ""
    @State private var devRightText = ""
    @State private var devCameraError = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("計測パネル").font(.headline)
                    Spacer()
                    Button("閉じる", action: onClose)
                }
                Button("キャリブレーション", action: onCalibrate)
                    .buttonStyle(.borderedProminent)
                Button(isLBoxOpen ? "L字の確認の箱を閉じる" : "L字の確認の箱を開く", action: onToggleLBox)
                    .buttonStyle(.bordered)
                Button("調整値を既定に戻す") { confirmReset = true }
                    .font(.caption)
                distanceSection
                Divider()
                rulerSection
                Divider()
                deviceSection
                Divider()
                roomSection
                Divider()
                trackingSection
                Divider()
                calibrationSection
                Divider()
                markerSection
                Divider()
                marginSection
                Divider()
                recordsSection
                Divider()
                chipSection
                Divider()
                copySection
                Divider()
                developerSection
            }
            .padding(14)
        }
        .alert("調整値を既定に戻しますか", isPresented: $confirmReset) {
            Button("戻す", role: .destructive) { diagnostics.resetTunes() }
            Button("やめる", role: .cancel) {}
        } message: {
            Text("壁の下げ量 30mm、p・w 自動（p の既定 1.0）、身長 ×1.0、距離の倍率 ×1.00、先読み 20ms などに戻します。キャリブレーションの結果、角度ごとの記録、クレカの棒は消えません")
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 50)
        .padding(.bottom, 80)
    }

    // MARK: 距離と遅れ

    private var distanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("距離と遅れの確認").font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let active = tracker.faceActive
                let rawCM = Double(tracker.rawDistance) * 100
                VStack(alignment: .leading, spacing: 3) {
                    Text(active ? String(format: "%.1f cm", rawCM) : "— cm")
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                    Text("ARKit の目までの距離（倍率を掛ける前）")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    row("倍率を掛けた距離", active ? String(format: "%.1f cm", rawCM * diagnostics.distanceScale) : "—")
                    row("描画までの遅れ（平均）", diagnostics.rig?.averageLatencyMS.map { String(format: "%.1f ms", $0) } ?? "—")
                }
                .font(.system(.footnote, design: .monospaced))
            }
            Button("本物の物と比べる", action: onCompare)
                .font(.caption)
            Text("遅れは ARKit のフレームの時刻から描画の命令を出し終えるまで。画面に光るまでの時間は含まない")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 実寸計測

    private var rulerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("① 実寸計測").font(.subheadline.bold())
            Text("クレジットカードの長辺（85.60mm）を画面に当て、棒の長さをカードに合わせる")
                .font(.caption)
            GeometryReader { geo in
                VStack(alignment: .leading, spacing: 8) {
                    Rectangle()
                        .fill(.yellow)
                        .frame(width: CGFloat(diagnostics.rulerBarLength), height: 14, alignment: .leading)
                    // 保存した値が今の幅より長くても切り詰めないよう、上限に含める
                    Slider(value: $diagnostics.rulerBarLength, in: 40...max(Double(geo.size.width), 100, diagnostics.rulerBarLength))
                }
            }
            .frame(height: 56)
            let mmPerPt = Self.cardLongSideMM / max(diagnostics.rulerBarLength, 1)
            Text("棒 \(String(format: "%.1f", diagnostics.rulerBarLength)) pt ＝ 85.60 mm → \(String(format: "%.4f", mmPerPt)) mm/pt（\(String(format: "%.2f", 1 / mmPerPt)) pt/mm）")
                .font(.system(.footnote, design: .monospaced))
        }
    }

    // MARK: 端末情報

    private var deviceSection: some View {
        let screen = UIScreen.main
        let b = screen.bounds
        let nb = screen.nativeBounds
        return VStack(alignment: .leading, spacing: 3) {
            Text("② 端末情報").font(.subheadline.bold())
            row("hw.machine", HologramDeviceProfile.readMachineID())
            row("1pt あたり", "\(String(format: "%.3f", diagnostics.mmPerPt)) mm（iPhone Duo 実寸）")
            row("bounds", "\(fmt(b.width)) × \(fmt(b.height)) pt")
            row("nativeBounds", "\(fmt(nb.width)) × \(fmt(nb.height)) px")
            row("nativeScale", fmt(screen.nativeScale))
            if let fold = diagnostics.foldY {
                row("折り目Y", "\(fmt(fold)) pt ／ \(String(format: "%.1f", Double(fold) * diagnostics.mmPerPt)) mm")
            } else {
                let fold = diagnostics.cameraProfile.foldYPt
                row("折り目Y", "取得なし（画面中央で代用：\(fmt(fold)) pt ／ \(String(format: "%.1f", Double(fold) * diagnostics.mmPerPt)) mm）")
            }
            cameraRows
            if let deg = hinge.angleDegrees {
                row("ヒンジ角度", "\(fmt(CGFloat(deg)))°")
            } else {
                row("ヒンジ角度", "取得なし（全開扱い）")
            }
            row("材質", "総数 \(diagnostics.materialTotal)／修正対象 \(diagnostics.materialFound)/2 見つかった")
        }
        .font(.system(.footnote, design: .monospaced))
    }

    /// 読み取ったカメラ位置（pt と mm、上端・折り目・横中央からの距離）
    @ViewBuilder private var cameraRows: some View {
        let p = diagnostics.cameraProfile
        let mm = HologramDeviceProfile.mmPerPoint
        switch p.cameraSource {
        case .occlusion:
            row("カメラ位置の出どころ", "occlusion")
        case .manual:
            row("カメラ位置の出どころ", "手で合わせた値")
        case .fallback:
            row("カメラ位置の出どころ", "既定値")
        case .lowerPanel:
            row("カメラ位置の出どころ", "既定値")
            Text("カメラが下側：向きを変えてください").foregroundStyle(.red)
        }
        row("使用中のカメラ位置", HologramDeviceProfile.cameraPositionText(belowTopMM: p.cameraBelowTopMM, rightMM: p.cameraRightMM))
        if let below = p.occlusionBelowTopMM, let right = p.occlusionRightMM {
            row("occlusion の位置", HologramDeviceProfile.cameraPositionText(belowTopMM: below, rightMM: right))
        }
        row("選んだ映像の向き", "\(tracker.videoTurns * 90)°")
        row("軸対応の結果", diagnostics.calibrationResult ?? "キャリブレーション未実施")
        row("箱の確認", diagnostics.boxCheck.map { $0 ? "はい（奥に止まって見える）" : "いいえ（G2・G3 をやり直す）" } ?? "未回答")
        row("occlusion 変換前 frame（使用）", p.occlusionRawFrame.map(frameText) ?? "なし")
        row("occlusion 変換後 frame（使用）", p.occlusionFrame.map(frameText) ?? "なし")
        row("occlusion 変換の根拠", p.occlusionMethod ?? "—")
        row("occlusion 有効な数", "\(p.occlusionFrames.count)")
        ForEach(Array(p.occlusionFrames.enumerated()), id: \.offset) { i, f in
            row("　frame \(i + 1) 変換前", i < p.occlusionRawFrames.count ? frameText(p.occlusionRawFrames[i]) : "—")
            row("　frame \(i + 1) 変換後", frameText(f))
        }
        if let c = p.cameraCenterPt {
            row("occlusion 中心", "x \(fmt(c.x)) y \(fmt(c.y)) pt")
            let above = p.foldYPt - c.y
            row("折り目から（上が正）", "\(fmt(above)) pt ／ \(String(format: "%.1f", Double(above) * mm)) mm")
        }
    }

    private func frameText(_ f: CGRect) -> String {
        "x \(fmt(f.minX)) y \(fmt(f.minY)) w \(fmt(f.width)) h \(fmt(f.height))"
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            Text(value).multilineTextAlignment(.trailing)
        }
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }

    // MARK: 部屋・配置

    private var roomSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("③ 部屋・配置").font(.subheadline.bold())
            Text("壁を奥へ下げる量 wallRecess: \(String(format: "%.0f", diagnostics.wallRecessMM)) mm（初期 30）")
                .font(.caption)
            Slider(value: $diagnostics.wallRecessMM, in: 0...100, step: 1)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let effective = diagnostics.rig?.snapshot.effectiveRecessMM ?? Float(diagnostics.wallRecessMM)
                row("実効（mm）", String(format: "%.1f", effective))
                    .font(.system(.footnote, design: .monospaced))
            }
            Text("身長の倍率（自動で決めた身長に掛かる）: ×\(String(format: "%.2f", diagnostics.heightScale))")
                .font(.caption)
            Slider(value: $diagnostics.heightScale, in: 0.5...2, step: 0.05)
            Toggle("前後位置 p は角度で自動（既定 \(String(format: "%.1f", HologramRig.defaultPPos))／記録があれば補間）", isOn: $diagnostics.pAuto)
                .font(.caption)
            Text("前後位置 p（手動）: \(String(format: "%.2f", diagnostics.pPos))（0＝手前の端、1＝折り目、1超＝床の角まで）")
                .font(.caption)
            // 上限は床の角（pMax）。折り角と wallRecess で変わるので現在値を読む
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let pMax = Double(diagnostics.rig?.snapshot.pMax ?? 1.6)
                // 角度で pMax が縮んでも保存した p を切り詰めないよう、上限に含める
                Slider(value: $diagnostics.pPos, in: 0...max(pMax, 0.01, diagnostics.pPos), step: 0.01)
                    .disabled(diagnostics.pAuto)
            }
            Toggle("向き w は角度で自動（110°で 0 → 170°で 1）", isOn: $diagnostics.wAuto)
                .font(.caption)
            Text("向き w（手動）: \(String(format: "%.2f", diagnostics.wLean))（0＝床に垂直、1＝真上）")
                .font(.caption)
            Slider(value: $diagnostics.wLean, in: 0...1, step: 0.01)
                .disabled(diagnostics.wAuto)
            Toggle("格子を表示（床と壁、20mm間隔）", isOn: $diagnostics.showGrid)
                .font(.caption)
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let s = diagnostics.rig?.snapshot ?? HologramRig.Snapshot()
                VStack(alignment: .leading, spacing: 3) {
                    row("身長（実際）", "\(fmt(CGFloat(s.charHeightMM))) mm")
                    row("身長（自動）", "\(fmt(CGFloat(s.autoHeightMM))) mm")
                    row("前後位置 p（実際）", String(format: "%.2f", s.pEff))
                    row("向き w（実際）", String(format: "%.2f", s.wEff))
                    row("台座が下画面に乗る割合", String(format: "%.0f %%", s.padPct))
                    row("目の位置(上パネル座標)", String(format: "x%.0f y%.0f z%.0f mm", s.eye.x * 1000, s.eye.y * 1000, s.eye.z * 1000))
                    row("折り角度", "\(fmt(CGFloat(s.angleDeg)))°")
                    row("折り目の離れ（mm）", String(format: "%.2f", s.foldGapMM))
                    row("目の床からの高さ", "\(fmt(CGFloat(s.lowerEyeHeightMM))) mm")
                    row("下ビューの投影", s.lowerValid ? "有効" : "無効（目が床の裏側）")
                }
                .font(.system(.footnote, design: .monospaced))
            }
        }
    }

    // MARK: 顔トラッキング診断

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("④ 顔トラッキング診断").font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let d = tracker.diagnosticsSnapshot()
                let since: String = d.lastFrameTime.map { String(format: "%.1f 秒前", CACurrentMediaTime() - $0) } ?? "なし"
                VStack(alignment: .leading, spacing: 3) {
                    row("isSupported", d.isSupported ? "true" : "false")
                    row("カメラ権限", d.authorization)
                    row("セッション", d.sessionState)
                    row("フレーム数", "\(d.frames)（最後: \(since)）")
                    row("アンカー", "計\(d.lastAnchorCount)／顔\(d.lastFaceAnchorCount)／isTracked \(d.lastFaceTracked.map { $0 ? "true" : "false" } ?? "—")")
                    row("カメラ状態", d.cameraState)
                    row("対応フォーマット数", "\(d.videoFormats)")
                    row("中断", d.interrupted ? "中断中" : "なし")
                    row("エラー", d.lastError ?? "なし")
                    row("顔の最終捕捉", tracker.secondsSinceFace.map { "\($0) 秒前" } ?? "まだ一度もなし")
                }
                .font(.system(.footnote, design: .monospaced))
            }
            Text("読み方：フレーム数が増えない→カメラが来ていない／増えるのに顔0→カメラに顔が映っていない")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 視点（絶対位置・軸対応）

    private func axisBinding(isX: Bool) -> Binding<Int> {
        Binding(
            get: {
                let m = tracker.axisMap
                return isX ? HeadTracker.AxisMap.code(axis: m.xAxis, sign: m.xSign)
                           : HeadTracker.AxisMap.code(axis: m.yAxis, sign: m.ySign)
            },
            set: { c in
                var m = tracker.axisMap
                let d = HeadTracker.AxisMap.decode(c)
                if isX { m.xAxis = d.axis; m.xSign = d.sign } else { m.yAxis = d.axis; m.ySign = d.sign }
                tracker.setAxisMap(m)
            })
    }

    private var calibrationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⑥ 視点（絶対位置・軸対応）").font(.subheadline.bold())
            Text("目の位置は絶対位置のみ：カメラの位置（機種プロファイル）＋ 軸対応後の目位置。ホーム記録と視差ゲインは廃止した")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))

            // 変換前後の表示：カメラ座標（ARKit）→ 画面座標（viewMatrix）→ 軸対応後 → シーン座標
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let h = tracker.head
                let mp = tracker.mappedHead
                let r = tracker.rawRel
                let s = diagnostics.rig?.snapshot ?? HologramRig.Snapshot()
                VStack(alignment: .leading, spacing: 3) {
                    let sc = tracker.screenRel
                    row("変換前 カメラ座標(m)", String(format: "x%+.3f y%+.3f z%+.3f", r.x, r.y, r.z))
                    row("変換後 画面座標(m)", String(format: "x%+.3f y%+.3f z%+.3f", sc.x, sc.y, sc.z))
                    row("距離 −z 丸め前／後", String(format: "%+.3f ／ %.3f m", tracker.rawDistance, h.z))
                    row("距離の符号が逆", "\(tracker.wrongSignCount) 回")
                    row("使用中 head(m)", String(format: "x%+.3f y%+.3f z%+.3f", h.x, h.y, h.z))
                    row("軸対応後(m)", String(format: "x%+.3f y%+.3f z%+.3f", mp.x, mp.y, mp.z))
                    row("シーン座標(m)", String(format: "x%+.3f y%+.3f z%+.3f", s.eye.x, s.eye.y, s.eye.z))
                    row("顔", tracker.faceActive ? "捕捉中" : "見えていません")
                }
                .font(.system(.footnote, design: .monospaced))
            }

            Divider()
            Text("1€ フィルタと先読み（手順5）").font(.caption.bold())
            Text("最小カットオフ: \(String(format: "%.2f", diagnostics.oeMinCutoff)) Hz（小さいほど静止時に安定、大きいほど追従）")
                .font(.caption)
            Slider(value: $diagnostics.oeMinCutoff, in: 0.2...5, step: 0.05)
            Text("速度係数 β: \(String(format: "%.2f", diagnostics.oeBeta))（速く動いたときの追従の強さ）")
                .font(.caption)
            Slider(value: $diagnostics.oeBeta, in: 0...3, step: 0.05)
            Text("先読み: \(String(format: "%.0f", diagnostics.oePredMS)) ms（表示までの遅れの埋め合わせ）")
                .font(.caption)
            Slider(value: $diagnostics.oePredMS, in: HologramCalibrationStore.predictionRangeMS, step: 1)

        }
    }

    // MARK: 開発用（手動の軸対応とカメラ位置。保存先はキャリブレーションと同じ機種IDごと）

    private var developerSection: some View {
        let m = tracker.axisMap
        let p = diagnostics.cameraProfile
        return VStack(alignment: .leading, spacing: 8) {
            Text("開発用").font(.subheadline.bold())
            Text("距離の倍率: ×\(String(format: "%.2f", diagnostics.distanceScale))（機種ごとに保存）")
                .font(.caption)
            Slider(value: $diagnostics.distanceScale, in: HologramCalibrationStore.distanceScaleRange,
                   step: HologramCalibrationStore.distanceScaleStep)
            Divider()
            Text("軸対応（手動）").font(.caption.bold())
            Text("画面の右＝ \(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: m.xAxis, sign: m.xSign)])　画面の上＝ \(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: m.yAxis, sign: m.ySign)])（画面座標の軸）")
                .font(.system(.footnote, design: .monospaced))
            HStack {
                Text("X").font(.caption)
                Picker("X", selection: axisBinding(isX: true)) {
                    ForEach(0..<6, id: \.self) { Text(HeadTracker.AxisMap.labels[$0]).tag($0) }
                }.pickerStyle(.segmented)
            }
            HStack {
                Text("Y").font(.caption)
                Picker("Y", selection: axisBinding(isX: false)) {
                    ForEach(0..<6, id: \.self) { Text(HeadTracker.AxisMap.labels[$0]).tag($0) }
                }.pickerStyle(.segmented)
            }
            Divider()
            Text("カメラ位置（手動）").font(.caption.bold())
            Text(HologramDeviceProfile.cameraPositionText(belowTopMM: p.cameraBelowTopMM, rightMM: p.cameraRightMM))
                .font(.system(.footnote, design: .monospaced))
            HStack {
                TextField("上端から下へ mm", text: $devBelowText)
                TextField("中央から右へ mm（左は −）", text: $devRightText)
                Button("数値を保存", action: saveDevCameraText)
            }
            .textFieldStyle(.roundedBorder)
            .keyboardType(.numbersAndPunctuation)
            .font(.caption)
            if devCameraError {
                Text("数値を確認してください（下へは 0 以上）").font(.caption2).foregroundStyle(.red)
            }
            CalibrationNudgePad { right, down in
                let below = Double(devBelowText) ?? p.cameraBelowTopMM
                let side = Double(devRightText) ?? p.cameraRightMM
                saveDevCamera(below: max(below + down, 0), right: side + right)
            }
        }
        .onAppear {
            devBelowText = String(format: "%.1f", p.cameraBelowTopMM)
            devRightText = String(format: "%.1f", p.cameraRightMM)
        }
    }

    private func saveDevCameraText() {
        guard let below = Double(devBelowText), let right = Double(devRightText),
              below.isFinite, right.isFinite, below >= 0 else {
            devCameraError = true
            return
        }
        saveDevCamera(below: below, right: right)
    }

    private func saveDevCamera(below: Double, right: Double) {
        devCameraError = false
        devBelowText = String(format: "%.1f", below)
        devRightText = String(format: "%.1f", right)
        diagnostics.saveManualCamera(belowTopMM: below, rightMM: right)
    }

    // MARK: マーカー（位置合わせ）

    private var markerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⑦ マーカー（位置合わせ確認）").font(.subheadline.bold())
            Toggle("マーカーを表示", isOn: $diagnostics.showMarkers)
                .font(.caption)
            Text("画面の角と折り目に印が出る（上パネルの角＝水色、折り目＝黄色、下パネルの角＝マゼンタ）。投影と寸法が合っていれば、頭を動かしても印は画面の角に張り付いたままになる")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
            Text("読み方：印の動きが頭より大きい・小さい → 寸法（mm/pt）かカメラ位置のずれ／印が頭と逆向きに動く → 軸対応が逆／折り目の印が上下で段差になる → 上下の描画で目の位置が食い違っている")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 見切れ余裕

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("⑧ 見切れ余裕（mm）").font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let s = diagnostics.rig?.snapshot ?? HologramRig.Snapshot()
                let labels = ["頭", "足", "台座の縁", "体の左右", "高さ 1/4", "高さ 1/2", "高さ 3/4"]
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<labels.count, id: \.self) { i in
                        marginRow(labels[i], value: i < s.marginsMM.count ? s.marginsMM[i] : .nan)
                    }
                }
                .font(.system(.footnote, design: .monospaced))
            }
            Text("点ごとに、数えられる窓（上パネルの上端と左右／下パネルの手前の端と左右）のうち大きい方の余裕を取り、グループ内の最小を出す。折り目側の辺は数えない。負は赤。— はどの窓でも数えられない")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    private func marginRow(_ name: String, value: Float) -> some View {
        HStack(alignment: .top) {
            Text(name).foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 8)
            Text(value.isNaN ? "—" : String(format: "%+.0f", value))
                .foregroundStyle(!value.isNaN && value < 0 ? .red : .white)
        }
    }

    // MARK: 角度ごとの記録

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⑨ 角度ごとの p・w 記録").font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let s = diagnostics.rig?.snapshot ?? HologramRig.Snapshot()
                VStack(alignment: .leading, spacing: 6) {
                    Text("いま：\(String(format: "%.0f", s.angleDeg))°／p \(String(format: "%.2f", s.pEff))／w \(String(format: "%.2f", s.wEff))")
                        .font(.system(.footnote, design: .monospaced))
                    Button("この角度の p と w を記録") {
                        diagnostics.recordCurrentPW(angleDeg: Double(s.angleDeg), p: Double(s.pEff), w: Double(s.wEff))
                    }
                    .font(.caption)
                }
            }
            if diagnostics.pwRecords.isEmpty {
                Text("記録はまだない").font(.caption2).foregroundStyle(.white.opacity(0.7))
            } else {
                ForEach(Array(diagnostics.pwRecords.enumerated()), id: \.offset) { i, r in
                    HStack {
                        Text("\(String(format: "%.0f", r.angleDeg))°: p \(String(format: "%.2f", r.p))／w \(String(format: "%.2f", r.w))")
                            .font(.system(.footnote, design: .monospaced))
                        Spacer(minLength: 8)
                        Button("削除") { diagnostics.deletePWRecord(at: i) }
                            .font(.caption)
                    }
                }
            }
            Text("記録できる角度は実機では約15°〜145°と全開（180°）。記録の間は p と w の既定値を角度で線形補間し、範囲の外は両端の記録の値を保つ（記録が1件なら全角度でその値）。記録がないときは既定（p=\(String(format: "%.1f", HologramRig.defaultPPos))、w は角度の smoothstep）")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: シェーダ書式チップ

    private var chipSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("⑤ シェーダ書式チップ（緑＝動いた／赤＝動かない）").font(.subheadline.bold())
            HStack(spacing: 14) {
                ForEach(ShaderChip.allCases) { chip in
                    VStack(spacing: 4) {
                        ShaderChipView(chip: chip)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(chip.label).font(.caption.bold())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ShaderChip.allCases) { Text("\($0.label): \($0.detail)") }
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: 設定のコピー

    private var copySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("⑩ 設定のコピー").font(.subheadline.bold())
            TimelineView(.periodic(from: .now, by: 0.5)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button("設定をテキストでコピー") {
                            UIPasteboard.general.string = settingsText()
                            copiedAt = Date()
                        }
                        .font(.caption)
                        if let copiedAt, context.date.timeIntervalSince(copiedAt) < 2 {
                            Text("コピーしました").font(.caption)
                        }
                    }
                    Text(settingsText())
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 数値を決まった桁の文字列にする。値が無い・有限でないときは「—」
    private func num(_ value: Double?, _ digits: Int = 1, signed: Bool = false) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%\(signed ? "+" : "").\(digits)f", value)
    }

    private func num(_ value: Float?, _ digits: Int = 1, signed: Bool = false) -> String {
        let converted: Double? = value.map { Double($0) }
        return num(converted, digits, signed: signed)
    }

    /// 現在の設定をプレーンテキストに組み立てる
    private func settingsText() -> String {
        let d = diagnostics
        let snapshot = d.rig?.snapshot
        let s = snapshot?.hasFrame == true ? snapshot : nil
        let camera = d.cameraProfile
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        var lines: [String] = []
        lines.append("【基本】")
        lines.append("ビルド: \(build)")
        lines.append("機種ID: \(HologramDeviceProfile.readMachineID())")
        lines.append("mm/pt: \(num(d.mmPerPt, 3))")
        lines.append("クレカの棒: \(num(d.rulerBarLength, 1)) pt → \(num(Self.cardLongSideMM / max(d.rulerBarLength, 1), 4)) mm/pt")
        lines.append("パネル寸法: 幅 \(num(s?.panelMM?.x)) mm／上 \(num(s?.panelMM?.y)) mm／下 \(num(s?.panelMM?.z)) mm")

        lines.append("")
        lines.append("【カメラ】")
        let sourceLabel: String
        switch camera.cameraSource {
        case .occlusion: sourceLabel = "occlusion"
        case .manual: sourceLabel = "手で合わせた値"
        case .fallback: sourceLabel = "既定値"
        case .lowerPanel: sourceLabel = "既定値（カメラが下パネル側）"
        }
        // pt は occlusion から読めて実際に使っているときだけ出す（既定値には pt の実測がない）
        let usedCenter = camera.cameraSource == .occlusion ? camera.cameraCenterPt : nil
        let rightPt = usedCenter.map { Double($0.x - camera.viewWidthPt / 2) }
        lines.append("取得元: \(sourceLabel)")
        lines.append("位置: \(HologramDeviceProfile.cameraPositionText(belowTopMM: camera.cameraBelowTopMM, rightMM: camera.cameraRightMM))")
        lines.append("上端から: \(num(usedCenter.map { Double($0.y) }, 2)) pt／\(num(camera.cameraBelowTopMM)) mm")
        lines.append("横中央から（右が正）: \(num(rightPt, 2, signed: true)) pt／\(num(camera.cameraRightMM, 1, signed: true)) mm")
        lines.append("occlusion 変換前 frame（有効 \(camera.occlusionRawFrames.count) 個）: \(camera.occlusionRawFrames.isEmpty ? "なし" : camera.occlusionRawFrames.map(frameText).joined(separator: " ／ "))")
        lines.append("occlusion 変換後 frame: \(camera.occlusionFrames.isEmpty ? "なし" : camera.occlusionFrames.map(frameText).joined(separator: " ／ "))")
        lines.append("occlusion 変換の根拠: \(camera.occlusionMethod ?? "—")")
        if camera.cameraSource == .lowerPanel, let c = camera.cameraCenterPt {
            lines.append("読み取った中心（未使用）: x \(num(Double(c.x), 2)) y \(num(Double(c.y), 2)) pt")
        }
        lines.append("選んだ映像の向き: \(tracker.videoTurns * 90)°")
        lines.append("軸対応: x=\(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: tracker.axisMap.xAxis, sign: tracker.axisMap.xSign)]) y=\(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: tracker.axisMap.yAxis, sign: tracker.axisMap.ySign)])")
        lines.append("キャリブレーション: \((d.calibrationResult ?? "未実施").replacingOccurrences(of: "\n", with: "／"))")
        lines.append("箱の確認: \(d.boxCheck.map { $0 ? "はい" : "いいえ" } ?? "未回答")")
        lines.append("下パネル側の警告: \(camera.cameraSource == .lowerPanel ? "あり" : "なし")")
        let foldY = d.foldY ?? (camera.foldYPt > 0 ? camera.foldYPt : nil)
        let foldNote = d.foldY == nil && foldY != nil ? "（画面中央で代用）" : ""
        lines.append("折り目 foldY: \(num(foldY.map { Double($0) }, 2)) pt\(foldNote)")
        lines.append("折り目の離れ G: \(num(s?.foldGapMM, 2)) mm")

        lines.append("")
        lines.append("【調整値】")
        lines.append("壁の下げ量: スライダー \(num(d.wallRecessMM)) mm／実効 \(num(s?.effectiveRecessMM)) mm")
        lines.append("前後位置 p: \(d.pAuto ? "自動" : "手動")／実効 \(num(s?.pEff, 2))／pMax \(num(s?.pMax, 2))")
        lines.append("向き w: \(d.wAuto ? "自動" : "手動")／実効 \(num(s?.wEff, 2))")
        lines.append("身長: 倍率 ×\(num(d.heightScale, 2))／自動 \(num(s?.autoHeightMM)) mm")
        lines.append("格子: \(d.showGrid ? "ON" : "OFF")")
        lines.append("マーカー: \(d.showMarkers ? "ON" : "OFF")")

        lines.append("")
        lines.append("【1€ フィルタ】")
        lines.append("最小カットオフ: \(num(d.oeMinCutoff, 2)) Hz")
        lines.append("β: \(num(d.oeBeta, 2))")
        lines.append("先読み: \(num(d.oePredMS, 0)) ms")
        lines.append("先読み上限: \(num(HologramRig.predictionLimit(seconds: Float(d.oePredMS / 1000)) * 1000)) mm")
        lines.append("距離の倍率: ×\(num(d.distanceScale, 2))")
        lines.append("描画までの遅れ（平均）: \(num(d.rig?.averageLatencyMS, 1)) ms")

        lines.append("")
        lines.append("【定数】")
        lines.append("cornerFadeStartDeg: \(num(HologramRig.cornerFadeStartDeg, 0))°")
        lines.append("cornerFadeEndDeg: \(num(HologramRig.cornerFadeEndDeg, 0))°")
        lines.append("foldGapMaxMM: \(num(HologramDeviceProfile.foldGapMaxMM, 2)) mm")
        lines.append("開いてください表示: \(num(HologramView.openPromptShowBelowDeg, 0))° 未満で表示／\(num(HologramView.openPromptHideAtDeg, 0))° 以上で消す")

        lines.append("")
        lines.append("【角度ごとの p・w 記録】")
        if d.pwRecords.isEmpty {
            lines.append("記録なし")
        } else {
            for r in d.pwRecords {
                lines.append("\(num(r.angleDeg, 0))°: p \(num(r.p, 2))／w \(num(r.w, 2))")
            }
        }

        lines.append("")
        lines.append("【現在の状態】")
        lines.append("ヒンジ角度: \(num(hinge.angleDegrees))°")
        let minMargin = s?.marginsMM.filter { !$0.isNaN }.min()
        lines.append("見切れ余裕の最小: \(num(minMargin, 1, signed: true)) mm")
        lines.append("台座が下パネルに収まる割合: \(num(s?.padPct, 0)) %")
        return lines.joined(separator: "\n")
    }
}

/// 修飾子の書式の検証用。成功すれば緑、失敗（コンパイルできない）なら下地の赤のまま。
enum ShaderChip: String, CaseIterable, Identifiable {
    case a, b, c, d
    var id: String { rawValue }

    var label: String { rawValue.uppercased() }

    var detail: String {
        switch self {
        case .a: return ".fragment を Metal 書式（float3）"
        case .b: return ".fragment を GLSL 書式（vec3）"
        case .c: return ".lightingModel で _lightingContribution.diffuse と _light.direction"
        case .d: return ".fragment で _surface.view"
        }
    }

    var entryPoint: SCNShaderModifierEntryPoint {
        self == .c ? .lightingModel : .fragment
    }

    var source: String {
        switch self {
        case .a:
            return "float3 g = float3(0.0, 1.0, 0.0);\n_output.color.rgb = g;"
        case .b:
            return "vec3 g = vec3(0.0, 1.0, 0.0);\n_output.color.rgb = g;"
        case .c:
            // 光は赤、素材は白。修飾子が動けば寄与が緑に置き換わって緑になり、動かなければ赤のまま
            return "float d = abs(dot(_surface.normal, _light.direction));\n"
                + "_lightingContribution.diffuse += float3(0.0, 1.0, 0.0) * (0.6 + 0.4 * d);"
        case .d:
            return "float k = 0.6 + 0.4 * clamp(abs(_surface.view.z), 0.0, 1.0);\n"
                + "_output.color.rgb = float3(0.0, 1.0, 0.0) * k;"
        }
    }
}

/// 赤い小片を1枚描く SCNView。C だけ赤い光＋白い素材（ライティングを通す）、他は無陰影の赤。
struct ShaderChipView: UIViewRepresentable {
    let chip: ShaderChip

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .red          // 板が描けなかった場合も赤
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .none
        view.preferredFramesPerSecond = 15
        view.isPlaying = true                // 修飾子のコンパイル後に確実に描き直す

        let scene = SCNScene()
        let material = SCNMaterial()
        if chip == .c {
            material.lightingModel = .lambert
            material.diffuse.contents = UIColor.white
            let lightNode = SCNNode()
            lightNode.light = SCNLight()
            lightNode.light?.type = .directional
            lightNode.light?.color = UIColor.red
            lightNode.light?.intensity = 1000
            lightNode.position = SCNVector3(0, 0, 3)    // 板の手前から奥（-Z）へ照らす
            scene.rootNode.addChildNode(lightNode)
        } else {
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.red
        }
        material.shaderModifiers = [chip.entryPoint: chip.source]

        let plane = SCNPlane(width: 1, height: 1)
        plane.materials = [material]
        scene.rootNode.addChildNode(SCNNode(geometry: plane))

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.usesOrthographicProjection = true
        cameraNode.camera?.orthographicScale = 0.5
        cameraNode.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(cameraNode)

        view.scene = scene
        view.pointOfView = cameraNode
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}
