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

        // 雨衣ちゃん（公式MMDモデルを USDZ に変換したもの）。台座の上に立たせ、ゆっくり上下に浮遊させる
        let charH = min(totalH * 0.55, 0.115)
        characterNode.removeAllActions()
        characterNode.geometry = nil
        characterNode.childNodes.forEach { $0.removeFromParentNode() }
        if let url = Bundle.main.url(forResource: "amekoro", withExtension: "usdz"),
           let modelScene = try? SCNScene(url: url, options: nil) {
            let wrap = SCNNode()
            for child in Array(modelScene.rootNode.childNodes) { wrap.addChildNode(child) }
            // モデルの実寸（約1.53m）を目標の高さへ縮小し、足元が原点に来るようそろえる
            let (minB, maxB) = wrap.boundingBox
            let h = max(maxB.y - minB.y, Float(0.001))
            let s = Float(charH) / h
            wrap.scale = SCNVector3(s, s, s)
            wrap.position = SCNVector3(-minB.x * s, -minB.y * s, -minB.z * s)
            // USDZ の PBR のままだと陰影が灰色っぽく沈むので、全マテリアルを
            // テクスチャ色そのままの無陰影（.constant）にしてアニメ塗りの色を出す
            wrap.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { $0.lightingModel = .constant }
            }
            characterNode.addChildNode(wrap)
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
            characterNode.addChildNode(holder)
        }
        characterNode.position = SCNVector3(0, floorY + 0.004, padZ)
        // 向きは毎フレーム update() で視点のほうへ回す（SCNBillboardConstraint は
        // 2つの view のカメラを区別できず片方にしか向かないため使わない）
        let bob = SCNAction.sequence([
            .moveBy(x: 0, y: 0.005, z: 0, duration: 1.6),
            .moveBy(x: 0, y: -0.005, z: 0, duration: 1.6)
        ])
        bob.timingMode = .easeInEaseOut
        characterNode.runAction(.repeatForever(bob))
        worldNode.addChildNode(characterNode)
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

        // キャラは視点のほうへ向ける（Y 軸まわりだけ）
        let c = characterNode.simdPosition
        characterNode.eulerAngles.y = atan2(eye.x - c.x, eye.z - c.z)
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
    }

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

    func makeUIView(context: Context) -> HologramContainerView {
        let view = HologramContainerView(frame: .zero)
        view.tracker = tracker
        view.hinge = hinge
        return view
    }

    func updateUIView(_ uiView: HologramContainerView, context: Context) {}
}
