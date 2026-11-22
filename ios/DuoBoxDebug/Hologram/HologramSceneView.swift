import SceneKit
import SwiftUI

/// 共有シーン＋2つのカメラ。折り目対応レンダリング（第2パス）の本体。
///
/// 「曲がった窓」モデル：画面を折り目で上下2枚の物理的な平面に分け、各平面を別々の off-axis 投影で描く。
/// 世界座標（メートル）は **上半分の平面の座標系**：折り目が原点を通る x 軸、上半分は z = 0 の面で y > 0、
/// 画面の手前（利用者側）が +z、箱（部屋）は z < 0 に広がる。
/// 下半分の平面は、折り目まわりにヒンジ角ぶん回った面。全開（180°）なら上半分と同一平面になり、
/// 2つの投影は継ぎ目なくつながって単一投影と等価になる。
/// キャラと台座は3D空間のノードなので、折り目を跨いでも曲がらない。
/// 小数部（Float）。
private func frac(_ x: Float) -> Float { x - x.rounded(.down) }

final class HologramRig {
    let scene = SCNScene()
    let upperCamera = SCNNode()
    let lowerCamera = SCNNode()

    var tracker: HeadTracker?
    var hinge: HingeMonitor?
    /// ドラッグ用の手動視点（上半分の平面座標）
    var manual = SIMD3<Float>(0, 0, 0.30)

    // 画面の物理サイズ（端末ごとの実寸は取れないので、短辺 6.5cm 程度の想定値で近似する）
    static let shortSide: Float = 0.065
    private let boxDepth: Float = 0.25

    private var width: Float = 0.065
    private var upperH: Float = 0.07
    private var lowerH: Float = 0.07
    private var builtFor = SIMD3<Float>(0, 0, 0)

    private let worldNode = SCNNode()
    private let characterNode = SCNNode()
    private let idleNode = SCNNode()
    private let shadowNode = SCNNode()
    private var particles: [(node: SCNNode, base: SIMD3<Float>, phase: Float)] = []
    private var baseY: Float = 0          // キャラの足元の高さ（台座の上）
    private var charBuilt = false

    /// 読み込み済みのモデル（USDZ は 41MB あるので1回だけ読む。折り目が変わっても読み直さない）
    private var cachedModel: (node: SCNNode, minB: SCNVector3, maxB: SCNVector3)?
    private var modelLoadTried = false
    /// 材質名で見つかった修正対象の数と、モデルの材質の総数（計測パネル用）
    private(set) var materialFound = 0
    private(set) var materialTotal = 0

    private var smoothedEye = SIMD3<Float>(0, 0, 0.30)
    private var smoothedAngle: Float = .pi     // 全開 180° から始める
    private var lastTime: TimeInterval = 0

    init() {
        scene.rootNode.addChildNode(worldNode)
        upperCamera.camera = SCNCamera()
        lowerCamera.camera = SCNCamera()
        scene.rootNode.addChildNode(upperCamera)
        scene.rootNode.addChildNode(lowerCamera)
        // USDZ の PBR マテリアル用に照明を足す（壁と台座は .constant なので影響を受けない）
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.position = SCNVector3(0.05, 0.15, 0.25)
        key.look(at: SCNVector3(0, 0, -0.1))
        scene.rootNode.addChildNode(key)
    }

    /// 上下の半分の大きさ（メートル）。変わったときだけ箱を作り直す。
    func configure(width: Float, upperH: Float, lowerH: Float) {
        self.width = width; self.upperH = upperH; self.lowerH = lowerH
        let key = SIMD3(width, upperH, lowerH)
        if key != builtFor {
            builtFor = key
            rebuildWorld()
        }
    }

    // MARK: - シーン構築

    private func rebuildWorld() {
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        let w = CGFloat(width), d = CGFloat(boxDepth)
        let totalH = CGFloat(upperH + lowerH)
        let floorY = -lowerH                       // 床は下半分の側（部屋の下端）
        let midY = (upperH - lowerH) / 2           // 部屋の縦方向の中心

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
        let back = wall(w, totalH, alpha: 0.35)
        back.position = SCNVector3(0, midY, -Float(d))
        let floor = wall(w, d, alpha: 0.5)
        floor.eulerAngles.x = -.pi / 2
        floor.position = SCNVector3(0, floorY, -Float(d) / 2)
        let left = wall(d, totalH, alpha: 0.3)
        left.eulerAngles.y = .pi / 2
        left.position = SCNVector3(-Float(w) / 2, midY, -Float(d) / 2)
        let right = wall(d, totalH, alpha: 0.3)
        right.eulerAngles.y = -.pi / 2
        right.position = SCNVector3(Float(w) / 2, midY, -Float(d) / 2)
        [back, floor, left, right].forEach { worldNode.addChildNode($0) }

        // 台座（円盤＋光るリング）。床＝下半分の側の中央。折り目（y = 0）からは常に離れている
        let padZ = -Float(d) * 0.45
        let radius = w * 0.33
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
        ringNode.runAction(.repeatForever(.sequence([
            .fadeOpacity(to: 0.35, duration: 1.1),
            .fadeOpacity(to: 1.0, duration: 1.1)
        ])))
        worldNode.addChildNode(pad)
        worldNode.addChildNode(ringNode)

        // キャラの真下の柔らかい影（光だまり）。浮遊に合わせて update() で濃さと大きさを変える
        let shadowPlane = SCNPlane(width: CGFloat(radius) * 0.9, height: CGFloat(radius) * 0.9)
        let shadowMat = SCNMaterial()
        shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = Self.softDiscImage()
        shadowMat.isDoubleSided = true
        shadowMat.writesToDepthBuffer = false
        shadowPlane.materials = [shadowMat]
        shadowNode.geometry = shadowPlane
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.position = SCNVector3(0, floorY + 0.0042, padZ)
        shadowNode.renderingOrder = 5
        worldNode.addChildNode(shadowNode)

        // 浮遊する微粒子（少数の小さな球。位置は update() でゆっくり漂わせる）
        particles.removeAll()
        let dotMat = SCNMaterial()
        dotMat.lightingModel = .constant
        dotMat.diffuse.contents = UIColor(red: 0.6, green: 0.95, blue: 1.0, alpha: 1)
        dotMat.blendMode = .add
        dotMat.writesToDepthBuffer = false
        for i in 0..<20 {
            let sphere = SCNSphere(radius: 0.0007)
            sphere.segmentCount = 6
            sphere.materials = [dotMat]
            let n = SCNNode(geometry: sphere)
            // 疑似乱数（再構築しても同じ配置になるよう固定式）
            let fi = Float(i)
            let rx = frac(sin(fi * 12.9898) * 43758.5453)
            let ry = frac(sin(fi * 78.233) * 12345.678)
            let rz = frac(sin(fi * 39.346) * 24680.13)
            let base = SIMD3<Float>((rx - 0.5) * width * 0.8,
                                    floorY + 0.01 + ry * (upperH + lowerH) * 0.85,
                                    -Float(d) * (0.1 + rz * 0.75))
            n.simdPosition = base
            worldNode.addChildNode(n)
            particles.append((n, base, fi * 1.7))
        }

        // 雨衣ちゃん（公式MMDモデルを USDZ に変換したもの）。台座の上に立たせ、ゆっくり上下に浮遊させる
        let charH = min(totalH * 0.55, 0.115)
        characterNode.removeAllActions()
        characterNode.geometry = nil
        characterNode.childNodes.forEach { $0.removeFromParentNode() }
        idleNode.childNodes.forEach { $0.removeFromParentNode() }
        if let model = loadModelOnce() {
            // モデルの実寸（約1.53m）を目標の高さへ縮小する。X・Z は中心、Y は足元を原点にそろえる
            let wrap = model.node
            let h = max(model.maxB.y - model.minB.y, Float(0.001))
            let s = Float(charH) / h
            let cx = (model.minB.x + model.maxB.x) / 2
            let cz = (model.minB.z + model.maxB.z) / 2
            wrap.scale = SCNVector3(s, s, s)
            wrap.position = SCNVector3(-cx * s, -model.minB.y * s, -cz * s)
            idleNode.addChildNode(wrap)
        } else {
            // モデルが読めないときの保険（従来の1枚絵プレーン）
            let plane = SCNPlane(width: charH * 2 / 3, height: charH)
            let cm = SCNMaterial()
            cm.lightingModel = .constant
            cm.diffuse.contents = AmekoroTexture.load()
            cm.isDoubleSided = true
            cm.transparencyMode = .aOne
            plane.materials = [cm]
            let holder = SCNNode(geometry: plane)
            holder.position = SCNVector3(0, Float(charH) / 2, 0)
            idleNode.addChildNode(holder)
        }
        idleNode.removeFromParentNode()
        characterNode.addChildNode(idleNode)

        baseY = floorY + 0.004
        charBuilt = true
        characterNode.position = SCNVector3(0, baseY, padZ)
        // 向きは正面固定（視点へは向けない。回り込むと横側が見える）。浮遊・傾きもなし
        characterNode.eulerAngles = SCNVector3Zero
        // 接地影は固定（浮遊しないので濃さも大きさも一定）
        shadowNode.opacity = 0.8
        worldNode.addChildNode(characterNode)
    }

    /// モデルを1回だけ読み、材質を修正してキャッシュする。読めなければ nil（以後も再試行しない）。
    private func loadModelOnce() -> (node: SCNNode, minB: SCNVector3, maxB: SCNVector3)? {
        if let cachedModel { return cachedModel }
        if modelLoadTried { return nil }
        modelLoadTried = true
        guard let url = Bundle.main.url(forResource: "amekoro", withExtension: "usdz"),
              let modelScene = try? SCNScene(url: url, options: nil) else { return nil }
        let wrap = SCNNode()
        for child in Array(modelScene.rootNode.childNodes) { wrap.addChildNode(child) }
        let (minB, maxB) = wrap.boundingBox
        // USDZ の PBR のままだと陰影が灰色っぽく沈むので、全マテリアルを
        // テクスチャ色そのままの無陰影（.constant）にしてアニメ塗りの色を出す
        wrap.enumerateChildNodes { node, _ in
            node.geometry?.materials.forEach { $0.lightingModel = .constant }
        }
        // 材質名で髪の二重描画（Beret_OFF）と透過髪の不透明度を直す
        let stats = AmekoroMaterials.apply(to: wrap)
        materialFound = stats.found
        materialTotal = stats.total
        let model = (node: wrap, minB: minB, maxB: maxB)
        cachedModel = model
        return model
    }

    /// 中心が濃く縁へ向けて消える、暗い半透明の円（影用）。
    private static func softDiscImage() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.75).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: size.width / 2, options: [])
        }
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
            UIColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 0.9).setStroke()
            g.setLineWidth(6)
            g.stroke(CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3))
        }
    }

    // MARK: - 毎フレーム

    /// 視点・折り角度を平滑化し、2つのカメラの投影を更新する。上半分の view の描画前に1回だけ呼ぶ。
    func update(time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(time - lastTime, 0.1)
        lastTime = time
        let k = Float(1 - exp(-dt * 12))

        // 視点：顔が見えていれば顔、そうでなければドラッグ。tracker の頭位置は上半分の平面座標（中心原点）
        let head: SIMD3<Float>
        if let tracker, tracker.faceActive { head = tracker.head } else { head = manual }
        smoothedEye += (head - smoothedEye) * k
        // 世界座標へ（上半分の平面の中心は y = upperH / 2）
        let eye = SIMD3<Float>(smoothedEye.x, smoothedEye.y + upperH / 2, max(smoothedEye.z, 0.1))

        // 折り角度：取れなければ全開 180°（＝従来の単一平面）。ライブ更新に追従
        let target = Float(min(max(hinge?.radians ?? .pi, .pi / 6), .pi))
        smoothedAngle += (target - smoothedAngle) * k
        let th = smoothedAngle

        // 上半分の平面：中心 (0, upperH/2, 0)、右 +x、上 +y、法線 +z
        setProjection(camera: upperCamera, eye: eye,
                      center: SIMD3(0, upperH / 2, 0),
                      right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0), normal: SIMD3(0, 0, 1),
                      halfW: width / 2, halfH: upperH / 2)

        // 下半分の平面：折り目まわりに回した面。d は折り目から下半分の端へ向かう向き。
        // th = π で d = (0,-1,0)（同一平面）、th = π/2 で d = (0,0,1)（手前へ倒れたL字）
        let d = SIMD3<Float>(0, cos(th), sin(th))
        setProjection(camera: lowerCamera, eye: eye,
                      center: d * (lowerH / 2),
                      right: SIMD3(1, 0, 0), up: -d, normal: SIMD3(0, sin(th), -cos(th)),
                      halfW: width / 2, halfH: lowerH / 2)

        updateIdle(time: Float(time.truncatingRemainder(dividingBy: 3600)))
    }

    /// アイドル演出：微粒子だけ残す（浮遊・傾き・呼吸・フリッカー・走査線は止めた）。
    private func updateIdle(time t: Float) {
        guard charBuilt else { return }

        // 微粒子：基準位置のまわりをゆっくり漂い、またたく
        for p in particles {
            let ph = p.phase
            p.node.simdPosition = p.base + SIMD3<Float>(0.004 * sin(t * 0.5 + ph),
                                                        0.006 * sin(t * 0.35 + ph * 1.3),
                                                        0.003 * sin(t * 0.42 + ph * 0.7))
            p.node.opacity = CGFloat(0.35 + 0.35 * sin(t * 0.9 + ph))
        }
    }

    /// 1枚の平面（中心・右・上・法線）を窓にした off-axis 投影を、カメラへ設定する。
    /// カメラは目の位置に置き、向きは平面に揃える（傾けず錐台を非対称にする）。
    private func setProjection(camera node: SCNNode, eye: SIMD3<Float>,
                               center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                               normal: SIMD3<Float>, halfW: Float, halfH: Float) {
        // 目を、この平面の座標系へ変換
        let v = eye - center
        let e = SIMD3<Float>(simd_dot(v, right), simd_dot(v, up), max(simd_dot(v, normal), 0.05))
        let near: Float = 0.01, far: Float = 2.0
        let l = (-halfW - e.x) * near / e.z
        let r = ( halfW - e.x) * near / e.z
        let b = (-halfH - e.y) * near / e.z
        let t = ( halfH - e.y) * near / e.z

        var m = SCNMatrix4Identity
        m.m11 = 2 * near / (r - l)
        m.m22 = 2 * near / (t - b)
        m.m31 = (r + l) / (r - l)
        m.m32 = (t + b) / (t - b)
        m.m33 = -(far + near) / (far - near)
        m.m34 = -1
        m.m43 = -2 * far * near / (far - near)
        m.m44 = 0

        // カメラの軸 = 平面の (右, 上, 法線)。カメラは -法線 方向（画面の奥）を見る
        node.simdTransform = simd_float4x4(columns: (
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(normal, 0), SIMD4(eye, 1)))
        node.camera?.projectionTransform = m
    }
}

/// 上下2つの SCNView を縦に並べるコンテナ。折り目の位置で上下を分ける。
final class HologramContainerView: UIView, SCNSceneRendererDelegate {
    let rig = HologramRig()
    var hinge: HingeMonitor? {
        didSet {
            rig.hinge = hinge
            hinge?.onFoldChange = { [weak self] in self?.setNeedsLayout() }
            if let hinge { hinge.attach(to: self) }
        }
    }
    var tracker: HeadTracker? { didSet { rig.tracker = tracker } }
    /// 計測パネル用の情報の受け渡し先と、パネルを開閉する三本指タップ
    var diagnostics: HologramDiagnostics?
    var onThreeFingerTap: (() -> Void)?

    private let upperView = SCNView()
    private let lowerView = SCNView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = UIColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)
        for (view, camera) in [(upperView, rig.upperCamera), (lowerView, rig.lowerCamera)] {
            view.backgroundColor = backgroundColor
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            view.scene = rig.scene           // 同じ SCNScene を2つの view で描く
            view.pointOfView = camera
            view.isPlaying = true            // 毎フレーム描画（浮遊アニメと視点更新のため）
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        // 投影の更新は上半分の view の描画前に1回だけ行い、下半分は同じ結果を使う
        upperView.delegate = self

        // 顔トラッキングが使えないときのドラッグ操作
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        // 三本指タップで計測パネルを開閉する
        let threeTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        threeTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeTap)
    }

    @objc private func handleThreeFingerTap() { onThreeFingerTap?() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // 折り目の位置：reserved regions（.division）が取れればその位置。
        // 取れない場合は画面中央で代用する（フォールバック。実機の折り目位置とずれうる）。
        // 折り目の帯の厚みは無視し、その中心線を境にする（v0）。
        let raw = hinge?.foldY(in: self) ?? bounds.height / 2
        let fold = min(max(raw, bounds.height * 0.2), bounds.height * 0.8)

        upperView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: fold)
        lowerView.frame = CGRect(x: 0, y: fold, width: bounds.width, height: bounds.height - fold)

        // ポイント → メートル。画面の短辺が shortSide になる尺度で、上下で同じ尺度を使う
        let mpp = HologramRig.shortSide / Float(min(bounds.width, bounds.height))
        rig.configure(width: Float(bounds.width) * mpp,
                      upperH: Float(fold) * mpp,
                      lowerH: Float(bounds.height - fold) * mpp)

        // 計測パネルへ：折り目のY位置（取れなければ nil）、材質の数
        let reportedFold: CGFloat? = hinge?.foldY(in: self)
        let found = rig.materialFound, total = rig.materialTotal
        DispatchQueue.main.async { [weak self] in
            guard let d = self?.diagnostics else { return }
            d.foldY = reportedFold
            d.materialFound = found
            d.materialTotal = total
        }
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // 指を右へ動かすと、視点が右へ動く（覗き込む感覚）
        rig.manual.x = min(max(rig.manual.x + Float(t.x) * 0.0004, -0.12), 0.12)
        rig.manual.y = min(max(rig.manual.y - Float(t.y) * 0.0004, -0.12), 0.12)
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        rig.update(time: time)
    }
}

/// SwiftUI から使うための橋渡し。
struct HologramSceneView: UIViewRepresentable {
    let tracker: HeadTracker
    let hinge: HingeMonitor
    let diagnostics: HologramDiagnostics
    let onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> HologramContainerView {
        let view = HologramContainerView(frame: .zero)
        view.tracker = tracker
        view.hinge = hinge
        view.diagnostics = diagnostics
        view.onThreeFingerTap = onThreeFingerTap
        return view
    }

    func updateUIView(_ uiView: HologramContainerView, context: Context) {
        uiView.onThreeFingerTap = onThreeFingerTap
    }
}
