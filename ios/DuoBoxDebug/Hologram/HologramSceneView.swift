import SceneKit
import SwiftUI

/// SceneKit の画面。画面を「箱を覗く窓」とみなし、頭の位置から off-axis 投影を作る。
///
/// 座標系はメートル。画面の面を z = 0、画面の中心を原点とし、箱は z < 0 側（画面の奥）に広がる。
final class HologramSCNView: SCNView, SCNSceneRendererDelegate {
    var tracker: HeadTracker?

    // 窓（画面）の物理サイズ。端末ごとの実寸は取れないので、短辺 6.5cm 程度の想定値で近似する（v0）
    private let shortSide: Float = 0.065
    private let boxDepth: Float = 0.25
    private var windowSize = SIMD2<Float>(0.065, 0.14)

    private let cameraNode = SCNNode()
    private let worldNode = SCNNode()       // 箱＋台座＋キャラ。窓サイズが変わったら作り直す
    private var builtForSize = SIMD2<Float>(0, 0)

    // 視点（平滑化済み）と、ドラッグ用の手動視点
    private var smoothed = SIMD3<Float>(0, 0, 0.30)
    private var manual = SIMD3<Float>(0, 0, 0.30)
    private var lastTime: TimeInterval = 0

    override init(frame: CGRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)
        antialiasingMode = .multisampling4X
        preferredFramesPerSecond = 60
        scene = SCNScene()
        scene?.rootNode.addChildNode(worldNode)
        cameraNode.camera = SCNCamera()
        scene?.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        delegate = self
        isPlaying = true  // 毎フレーム描画（浮遊アニメと視点更新のため）

        // 顔トラッキングが使えないときのドラッグ操作
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let long = shortSide * Float(max(bounds.width, bounds.height) / min(bounds.width, bounds.height))
        windowSize = bounds.width <= bounds.height
            ? SIMD2(shortSide, long) : SIMD2(long, shortSide)
        if windowSize != builtForSize {
            builtForSize = windowSize
            rebuildWorld()
        }
    }

    // MARK: - 操作

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // 指を右へ動かすと、視点が右へ動く（覗き込む感覚）
        manual.x = min(max(manual.x + Float(t.x) * 0.0004, -0.12), 0.12)
        manual.y = min(max(manual.y - Float(t.y) * 0.0004, -0.12), 0.12)
    }

    // MARK: - シーン構築

    private func rebuildWorld() {
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        let w = CGFloat(windowSize.x), h = CGFloat(windowSize.y), d = CGFloat(boxDepth)

        // 箱（内側が見える）。縁と格子のテクスチャで奥行きを出す
        func wall(_ pw: CGFloat, _ ph: CGFloat, alpha: CGFloat) -> SCNNode {
            let plane = SCNPlane(width: pw, height: ph)
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Self.gridImage(alpha: alpha)
            m.isDoubleSided = true
            m.blendMode = .add
            m.writesToDepthBuffer = false
            plane.materials = [m]
            return SCNNode(geometry: plane)
        }
        let back = wall(w, h, alpha: 0.35)
        back.position = SCNVector3(0, 0, -Float(d))
        let floor = wall(w, d, alpha: 0.5)
        floor.eulerAngles.x = -.pi / 2
        floor.position = SCNVector3(0, -Float(h) / 2, -Float(d) / 2)
        let left = wall(d, h, alpha: 0.3)
        left.eulerAngles.y = .pi / 2
        left.position = SCNVector3(-Float(w) / 2, 0, -Float(d) / 2)
        let right = wall(d, h, alpha: 0.3)
        right.eulerAngles.y = -.pi / 2
        right.position = SCNVector3(Float(w) / 2, 0, -Float(d) / 2)
        [back, floor, left, right].forEach { worldNode.addChildNode($0) }

        // 台座（円盤＋光るリング）。床の中央あたりに置く
        let floorY = -Float(h) / 2
        let padZ = -Float(d) * 0.45
        let radius = CGFloat(windowSize.x) * 0.33
        let disc = SCNCylinder(radius: radius, height: 0.003)
        let discMat = SCNMaterial()
        discMat.lightingModel = .constant
        discMat.diffuse.contents = UIColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 0.55)
        disc.materials = [discMat]
        let pad = SCNNode(geometry: disc)
        pad.position = SCNVector3(0, floorY + 0.002, padZ)

        let ring = SCNTorus(ringRadius: radius, pipeRadius: 0.0013)
        let ringMat = SCNMaterial()
        ringMat.lightingModel = .constant
        ringMat.diffuse.contents = UIColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 1)
        ring.materials = [ringMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, floorY + 0.004, padZ)
        // リングの明滅
        ringNode.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.35, duration: 1.1),
            .fadeOpacity(to: 1.0, duration: 1.1)
        ])))
        worldNode.addChildNode(pad)
        worldNode.addChildNode(ringNode)

        // 雨衣ちゃん（1枚絵プレーン）。台座の上に立たせ、ゆっくり上下に浮遊させる
        let charH = min(CGFloat(windowSize.y) * 0.5, 0.11)
        let plane = SCNPlane(width: charH * 2 / 3, height: charH)
        let cm = SCNMaterial()
        cm.lightingModel = .constant
        cm.diffuse.contents = AmekoroTexture.load()
        cm.isDoubleSided = true
        cm.transparencyMode = .aOne
        plane.materials = [cm]
        let character = SCNNode(geometry: plane)
        let baseY = floorY + 0.006 + Float(charH) / 2
        character.position = SCNVector3(0, baseY, padZ)
        // 常にカメラの正面を向く（縦には倒れないよう Y 軸まわりだけ回す）
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .Y
        character.constraints = [billboard]
        let bob = SCNAction.sequence([
            .moveBy(x: 0, y: 0.005, z: 0, duration: 1.6),
            .moveBy(x: 0, y: -0.005, z: 0, duration: 1.6)
        ])
        bob.timingMode = .easeInEaseOut
        character.runAction(.repeatForever(bob))
        worldNode.addChildNode(character)
    }

    /// 縁と格子線の入ったテクスチャ（半透明の青）。
    private static func gridImage(alpha: CGFloat) -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let g = ctx.cgContext
            UIColor(red: 0.02, green: 0.08, blue: 0.30, alpha: 1).withAlphaComponent(alpha).setFill()
            g.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.3, green: 0.7, blue: 1.0, alpha: 0.35).setStroke()
            g.setLineWidth(2)
            for i in stride(from: CGFloat(0), through: 256, by: 64) {
                g.move(to: CGPoint(x: i, y: 0)); g.addLine(to: CGPoint(x: i, y: 256))
                g.move(to: CGPoint(x: 0, y: i)); g.addLine(to: CGPoint(x: 256, y: i))
            }
            g.strokePath()
            // 縁のライン
            UIColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 0.9).setStroke()
            g.setLineWidth(6)
            g.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
        }
    }

    // MARK: - 毎フレーム

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(time - lastTime, 0.1)
        lastTime = time

        // 顔が見えていれば顔、そうでなければドラッグの視点を目標にする
        let target: SIMD3<Float>
        if let tracker, tracker.faceActive { target = tracker.head } else { target = manual }
        // 平滑化（フレームレートに依らない指数 lerp）
        let k = Float(1 - exp(-dt * 12))
        smoothed += (target - smoothed) * k

        applyOffAxisProjection(eye: smoothed)
    }

    /// off-axis 投影。画面（z = 0 の長方形）を窓として、目の位置から見える錐台を作る。
    /// カメラは目の位置に置き、向きは常に -z（画面に垂直）のまま。傾けず錐台のほうを非対称にする。
    private func applyOffAxisProjection(eye e: SIMD3<Float>) {
        let ez = max(e.z, 0.1)
        let near: Float = 0.01, far: Float = 2.0
        let halfW = windowSize.x / 2, halfH = windowSize.y / 2
        // 近平面上での窓の端（相似）
        let l = (-halfW - e.x) * near / ez
        let r = ( halfW - e.x) * near / ez
        let b = (-halfH - e.y) * near / ez
        let t = ( halfH - e.y) * near / ez

        var m = SCNMatrix4Identity
        m.m11 = 2 * near / (r - l)
        m.m22 = 2 * near / (t - b)
        m.m31 = (r + l) / (r - l)
        m.m32 = (t + b) / (t - b)
        m.m33 = -(far + near) / (far - near)
        m.m34 = -1
        m.m43 = -2 * far * near / (far - near)
        m.m44 = 0

        cameraNode.position = SCNVector3(e.x, e.y, ez)
        cameraNode.camera?.projectionTransform = m
    }
}

/// SwiftUI から使うための橋渡し。
struct HologramSceneView: UIViewRepresentable {
    let tracker: HeadTracker

    func makeUIView(context: Context) -> HologramSCNView {
        let view = HologramSCNView(frame: .zero)
        view.tracker = tracker
        return view
    }

    func updateUIView(_ uiView: HologramSCNView, context: Context) {}
}
