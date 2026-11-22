import SceneKit
import SwiftUI

/// 計測パネルへ渡す、画面（コンテナ）側で分かる値。
final class HologramDiagnostics: ObservableObject {
    /// 折り目のY位置（reserved regions が取れなければ nil＝画面中央で代用中）
    @Published var foldY: CGFloat?
    @Published var materialFound = 0
    @Published var materialTotal = 0
}

/// 三本指タップで開閉するデバッグパネル。実寸計測・端末情報・シェーダ書式チップ。
struct HologramDebugPanel: View {
    @ObservedObject var hinge: HingeMonitor
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
            row("hw.machine", Self.machineID())
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

    private static func machineID() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "不明" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: シェーダ書式チップ

    private var chipSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("③ シェーダ書式チップ（緑＝動いた／赤＝動かない）").font(.subheadline.bold())
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
