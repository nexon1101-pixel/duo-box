import QuartzCore
import SceneKit
import SwiftUI

/// 計測パネルへ渡す、画面（コンテナ）側で分かる値。
final class HologramDiagnostics: ObservableObject {
    /// 配置・描画の現在値を読むための参照（パネルが定期的に読む）
    weak var rig: HologramRig?
    /// 調整値：壁を奥へ下げる量（mm、初期値 30）と、身長の倍率（検証用、初期値 1）
    @Published var wallRecessMM: Double = 30
    @Published var heightScale: Double = 1
    /// 立ち位置（奥行き比）：0＝手前の端、1＝折り目（壁際）。既定 0.8＝折り目から床奥行きの20%手前
    @Published var pPos: Double = 0.5
    @Published var wAuto: Bool = true
    @Published var wLean: Double = 0
    /// 位置合わせマーカーの表示
    @Published var showMarkers = false
    /// 格子（床と壁）の表示
    @Published var showGrid = true
    /// 機種プロファイル
    @Published var profileID = ""
    @Published var profileIsFallback = true
    @Published var mmPerPt: Double = 0
    /// 折り目のY位置（reserved regions が取れなければ nil＝画面中央で代用中）
    @Published var foldY: CGFloat?
    @Published var materialFound = 0
    @Published var materialTotal = 0
}

/// 三本指タップで開閉するデバッグパネル。実寸計測・端末情報・シェーダ書式チップ。
struct HologramDebugPanel: View {
    @ObservedObject var hinge: HingeMonitor
    @ObservedObject var tracker: HeadTracker
    @ObservedObject var diagnostics: HologramDiagnostics
    var onClose: () -> Void

    /// クレジットカード（ISO/IEC 7810 ID-1）の長辺
    private static let cardLongSideMM: Double = 85.60
    @State private var barLength: Double = 200

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("計測パネル").font(.headline)
                    Spacer()
                    Button("閉じる", action: onClose)
                }
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
                chipSection
            }
            .padding(14)
        }
        .foregroundStyle(.white)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.top, 50)
        .padding(.bottom, 80)
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
                        .frame(width: CGFloat(barLength), height: 14, alignment: .leading)
                    Slider(value: $barLength, in: 40...Double(max(geo.size.width, 100)))
                }
            }
            .frame(height: 56)
            let mmPerPt = Self.cardLongSideMM / max(barLength, 1)
            Text("棒 \(String(format: "%.1f", barLength)) pt ＝ 85.60 mm → \(String(format: "%.4f", mmPerPt)) mm/pt（\(String(format: "%.2f", 1 / mmPerPt)) pt/mm）")
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
            row("プロファイル", diagnostics.profileIsFallback
                ? "未実測（近似）\(String(format: "%.4f", diagnostics.mmPerPt)) mm/pt"
                : "実測値 \(String(format: "%.4f", diagnostics.mmPerPt)) mm/pt")
            row("bounds", "\(fmt(b.width)) × \(fmt(b.height)) pt")
            row("nativeBounds", "\(fmt(nb.width)) × \(fmt(nb.height)) px")
            row("nativeScale", fmt(screen.nativeScale))
            if let fold = diagnostics.foldY {
                row("折り目Y", "\(fmt(fold)) pt")
            } else {
                row("折り目Y", "取得なし（画面中央で代用）")
            }
            if let deg = hinge.angleDegrees {
                row("ヒンジ角度", "\(fmt(CGFloat(deg)))°")
            } else {
                row("ヒンジ角度", "取得なし（全開扱い）")
            }
            row("材質", "総数 \(diagnostics.materialTotal)／修正対象 \(diagnostics.materialFound)/2 見つかった")
        }
        .font(.system(.footnote, design: .monospaced))
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
            Text("身長の倍率（自動で決めた身長に掛かる）: ×\(String(format: "%.2f", diagnostics.heightScale))")
                .font(.caption)
            Slider(value: $diagnostics.heightScale, in: 0.5...2, step: 0.05)
            Text("前後位置 p: \(String(format: "%.2f", diagnostics.pPos))（0＝手前の端、1＝折り目、1超＝床の角まで、既定 0.5）")
                .font(.caption)
            Slider(value: $diagnostics.pPos, in: 0...1.6, step: 0.01)
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

            // 変換前後の表示：rel（ARKit生）→ head（向き変換後）→ 変換後（軸対応適用後）→ シーン座標
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let h = tracker.head
                let mp = tracker.mappedHead
                let r = tracker.rawRel
                let s = diagnostics.rig?.snapshot ?? HologramRig.Snapshot()
                VStack(alignment: .leading, spacing: 3) {
                    row("真の生値 rel(m)", String(format: "x%+.3f y%+.3f z%+.3f", r.x, r.y, r.z))
                    row("変換後 head(m)", String(format: "x%+.3f y%+.3f z%+.3f", h.x, h.y, h.z))
                    row("軸対応後(m)", String(format: "x%+.3f y%+.3f z%+.3f", mp.x, mp.y, mp.z))
                    row("シーン座標(m)", String(format: "x%+.3f y%+.3f z%+.3f", s.eye.x, s.eye.y, s.eye.z))
                    row("顔", tracker.faceActive ? "捕捉中" : "見えていません")
                }
                .font(.system(.footnote, design: .monospaced))
            }

            // 軸対応は固定値。マーカー（⑦）で見て向きが逆なら、ここで直す
            Divider()
            Text("軸対応（固定値）").font(.caption.bold())
            Text("マーカーが頭と逆向きに動くときだけ、下の対応を直す。通常は触らない")
                .font(.caption2).foregroundStyle(.white.opacity(0.7))
            let m = tracker.axisMap
            Text("対応表：シーンX（右）＝ \(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: m.xAxis, sign: m.xSign)])　シーンY（上）＝ \(HeadTracker.AxisMap.labels[HeadTracker.AxisMap.code(axis: m.yAxis, sign: m.ySign)])（生座標の軸）")
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
        }
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
