import Combine
import SceneKit
import SwiftUI

/// 共有シーン＋2つのカメラ。折り目対応レンダリング（第2パス）の本体。
///
/// 「曲がった窓」モデル：画面を折り目で上下2枚の物理的な平面に分け、各平面を別々の off-axis 投影で描く。
/// 世界座標（メートル）は **上パネルの平面座標系**：折り目が原点を通る x 軸、上パネルは z = 0 の面で y > 0、
/// 画面の手前（利用者側）が +z。下パネルは折り目まわりにヒンジ角ぶん回った面。
///
/// 【縦伸び対策】上下の投影は Kooima の generalized perspective projection を同じ関数で計算する。
/// 入力は「同一の目の位置」と「同一の世界座標系での各パネルの角3点」だけで、パネルごとの尺度や
/// 補正（以前の max(e.z, 0.05) のクランプなど）は一切持たない。目がパネルの裏側に回って投影が成り立たない
/// ときは、ゆがんだ絵を出さずにそのビューを隠す。
///
/// 床＝下パネルの面、壁＝上パネルの面（wallRecess で奥へ下げられる）。キャラ・台座・影は floorFrame の子で、
/// 足は下パネルの中央に載り、体は下パネルの法線方向（面から利用者側）へ立つ。
/// 小数部（Float）。
private func frac(_ x: Float) -> Float { x - x.rounded(.down) }

final class HologramRig {
    let scene = SCNScene()
    let upperCamera = SCNNode()
    let lowerCamera = SCNNode()

    var tracker: HeadTracker?
    var hinge: HingeMonitor?
    /// 機種プロファイル（実寸とカメラ位置）。container が設定する
    var profile = HologramDeviceProfile.current()
    /// ドラッグ用の手動視点：基準の目の位置からのずれ（x, y のみ使う）
    var manual = SIMD3<Float>(0, 0, 0)

    /// キャラの身長を決める基準の折り角（115°）
    static let referenceAngle: Float = 115 * .pi / 180

    private var width: Float = 0.065
    private var upperH: Float = 0.07
    private var lowerH: Float = 0.07
    private var builtFor = SIMD3<Float>(0, 0, 0)

    // 調整値（メインスレッドで書き、描画スレッドで読む）
    private let tuneLock = NSLock()
    private var _wallRecess: Float = 0      // 壁を奥へ下げる量（m）
    private var _heightScale: Float = 1     // 身長の倍率（検証用）
    func setWallRecess(_ v: Float) { tuneLock.lock(); _wallRecess = max(v, 0); tuneLock.unlock() }
    func setHeightScale(_ v: Float) { tuneLock.lock(); _heightScale = max(v, 0.1); tuneLock.unlock() }
    private var wallRecess: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _wallRecess }
    private var heightScale: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _heightScale }

    private let worldNode = SCNNode()       // 壁と、壁側の暗がり
    private let floorFrame = SCNNode()      // 下パネルの面に合わせる枠（床・台座・影・キャラの親）
    private let characterNode = SCNNode()
    private let idleNode = SCNNode()
    private let shadowNode = SCNNode()
    private let wallNode = SCNNode()
    private let floorNode = SCNNode()
    private let wallShade = SCNNode()
    private let floorShade = SCNNode()
    private var particles: [(node: SCNNode, base: SIMD3<Float>, phase: Float)] = []
    private var charBuilt = false

    /// 基準角・基準視点で全身が下パネルに収まる身長（m）
    private(set) var baseCharHeight: Float = 0.03
    private let padHeight: Float = 0.002    // 台座の厚み（キャラの足はこの上）

    /// 読み込み済みのモデル（USDZ は 41MB あるので1回だけ読む。折り目が変わっても読み直さない）
    private var cachedModel: (node: SCNNode, minB: SCNVector3, maxB: SCNVector3)?
    private var modelLoadTried = false
    /// 材質名で見つかった修正対象の数と、モデルの材質の総数（計測パネル用）
    private(set) var materialFound = 0
    private(set) var materialTotal = 0

    private var smoothedEye = SIMD3<Float>(0, 0.1, 0.36)
    private var smoothedAngle: Float = .pi     // 全開 180° から始める
    private var lastTime: TimeInterval = 0
    private var eyeInitialized = false

    /// 下パネルの投影が成り立っているか（目が裏側に回ると false）。描画スレッドで更新
    private(set) var lowerValid = true

    /// 計測パネル用の値
    struct Snapshot {
        var eye = SIMD3<Float>(0, 0, 0)
        var angleDeg: Float = 180
        var charHeightMM: Float = 0
        var lowerEyeHeightMM: Float = 0
        var lowerValid = true
    }
    private let snapLock = NSLock()
    private var _snap = Snapshot()
    var snapshot: Snapshot { snapLock.lock(); defer { snapLock.unlock() }; return _snap }

    init() {
        scene.rootNode.addChildNode(worldNode)
        scene.rootNode.addChildNode(floorFrame)
        upperCamera.camera = SCNCamera()
        lowerCamera.camera = SCNCamera()
        scene.rootNode.addChildNode(upperCamera)
        scene.rootNode.addChildNode(lowerCamera)
        // USDZ の PBR マテリアル用に照明を足す（部屋と台座は .constant なので影響を受けない）
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

    /// 上下のパネルの大きさ（メートル）。変わったときだけ作り直す。
    func configure(width: Float, upperH: Float, lowerH: Float) {
        self.width = width; self.upperH = upperH; self.lowerH = lowerH
        let key = SIMD3(width, upperH, lowerH)
        if key != builtFor {
            builtFor = key
            rebuildWorld()
        }
    }

    // MARK: - 幾何

    /// 下パネルの面（折り目から端へ向かう向き d、中心、上方向、法線）を、折り角 th から求める。
    /// th = π で d = (0,-1,0)（上パネルと同一平面）、th = π/2 で d = (0,0,1)（手前へ倒れた L 字）。
    private func lowerPlane(angle th: Float) -> (d: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>, normal: SIMD3<Float>) {
        let d = SIMD3<Float>(0, cos(th), sin(th))
        return (d, d * (lowerH / 2), -d, SIMD3<Float>(0, sin(th), -cos(th)))
    }

    /// 基準の目の位置（上パネル座標）。画面の少し上、30〜40cm 手前を想定
    private var nominalEye: SIMD3<Float> { SIMD3<Float>(profile.cameraRight, upperH + 0.02, 0.36) }

    /// 基準角 115° で、基準視点の範囲（左右・上下・距離）を動いても、頭の先が下パネルの窓に収まる最大の身長。
    /// 床（下パネル）に立つ高さ H の点は、目の面内ずれ e∥・目の床からの高さ h として、
    /// 窓の上で足元から H·|e∥| / (h − H) だけ離れて見える。これが半窓幅以内になる H を、サンプルした視点の最小値で決める。
    private func computeFitHeight() -> Float {
        let plane = lowerPlane(angle: Self.referenceAngle)
        let base = nominalEye
        let mv = lowerH / 2 * 0.9          // 窓の縦の許容（半分の90%）
        let mx = width / 2 * 0.8           // 窓の横の許容（半分の80%：体の幅の余裕）
        var best = Float.greatestFiniteMagnitude
        for dx: Float in [-0.08, 0, 0.08] {
            for dy: Float in [-0.06, 0, 0.06] {
                for ez: Float in [0.25, 0.36, 0.45] {
                    let e = SIMD3<Float>(base.x + dx, base.y + dy, ez) - plane.center
                    let h = simd_dot(e, plane.normal)
                    guard h > 0.03 else { continue }   // 床より上にいない視点は対象外
                    let ev = abs(simd_dot(e, plane.up))
                    let ex = abs(e.x)
                    best = min(best, mv * h / (ev + mv), mx * h / (ex + mx))
                }
            }
        }
        guard best < Float.greatestFiniteMagnitude else { return 0.03 }
        return min(max(best, 0.02), 0.115)
    }

    // MARK: - シーン構築

    private func rebuildWorld() {
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        floorFrame.childNodes.forEach { $0.removeFromParentNode() }
        let w = CGFloat(width)

        baseCharHeight = computeFitHeight()
        let charH = baseCharHeight

        // 壁（上パネルの面）と床（下パネルの面）。位置と長さは折り角と wallRecess で変わるので update() で毎フレーム合わせる。
        // 幅は画面の3倍（目が横にずれても窓の外側まで部屋が続くように）
        func roomMaterial(_ c: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = c
            m.isDoubleSided = true
            return m
        }
        let wallPlane = SCNPlane(width: w * 3, height: 1)
        wallPlane.materials = [roomMaterial(UIColor(red: 0.21, green: 0.23, blue: 0.30, alpha: 1))]
        wallNode.geometry = wallPlane
        worldNode.addChildNode(wallNode)

        let floorPlane = SCNPlane(width: w * 3, height: 1)
        floorPlane.materials = [roomMaterial(UIColor(red: 0.15, green: 0.16, blue: 0.21, alpha: 1))]
        floorNode.geometry = floorPlane
        floorNode.eulerAngles.x = -.pi / 2           // 平面の法線を +y（床の上向き）へ
        floorFrame.addChildNode(floorNode)

        // 床と壁の境の柔らかい暗がり（部屋の角に見せる）。壁側は下が濃く、床側は壁際が濃い
        func shadeMaterial(darkAtTop: Bool) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = Self.cornerShadeImage(darkAtTop: darkAtTop)
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
            return m
        }
        let wallShadePlane = SCNPlane(width: w * 3, height: 0.03)
        wallShadePlane.materials = [shadeMaterial(darkAtTop: false)]
        wallShade.geometry = wallShadePlane
        wallShade.renderingOrder = 2
        worldNode.addChildNode(wallShade)
        let floorShadePlane = SCNPlane(width: w * 3, height: 0.03)
        floorShadePlane.materials = [shadeMaterial(darkAtTop: true)]
        floorShade.geometry = floorShadePlane
        floorShade.eulerAngles.x = -.pi / 2          // 平面の上端 → 床の -z（壁側）
        floorShade.renderingOrder = 2
        floorFrame.addChildNode(floorShade)

        // 台座：低い円盤＋細いリング1本（明滅なし）。floorFrame の原点＝下パネルの中央
        let radius = min(max(CGFloat(charH) * 0.45, 0.008), w * 0.3)
        let disc = SCNCylinder(radius: radius, height: CGFloat(padHeight))
        let discMat = SCNMaterial()
        discMat.lightingModel = .constant
        discMat.diffuse.contents = UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1)
        disc.materials = [discMat]
        let pad = SCNNode(geometry: disc)
        pad.position = SCNVector3(0, padHeight / 2, 0)
        floorFrame.addChildNode(pad)

        let ring = SCNTorus(ringRadius: radius, pipeRadius: 0.0006)
        let ringMat = SCNMaterial()
        ringMat.lightingModel = .constant
        ringMat.diffuse.contents = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)   // リボンの青
        ring.materials = [ringMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, padHeight + 0.0004, 0)
        floorFrame.addChildNode(ringNode)

        // 接地影：キャラの真下の濃い影（台座の上）
        let shadowPlane = SCNPlane(width: radius * 1.5, height: radius * 1.5)
        let shadowMat = SCNMaterial()
        shadowMat.lightingModel = .constant
        shadowMat.diffuse.contents = Self.softDiscImage()
        shadowMat.isDoubleSided = true
        shadowMat.writesToDepthBuffer = false
        shadowPlane.materials = [shadowMat]
        shadowNode.geometry = shadowPlane
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.position = SCNVector3(0, padHeight + 0.0008, 0)
        shadowNode.renderingOrder = 5
        shadowNode.opacity = 1.0
        floorFrame.addChildNode(shadowNode)

        // 浮遊する微粒子（少数の小さな球）。床の上、キャラのまわりを漂う
        particles.removeAll()
        let dotMat = SCNMaterial()
        dotMat.lightingModel = .constant
        dotMat.diffuse.contents = UIColor(red: 0.6, green: 0.95, blue: 1.0, alpha: 1)
        dotMat.blendMode = .add
        dotMat.writesToDepthBuffer = false
        for i in 0..<20 {
            let sphere = SCNSphere(radius: 0.0005)
            sphere.segmentCount = 6
            sphere.materials = [dotMat]
            let n = SCNNode(geometry: sphere)
            let fi = Float(i)
            let rx = frac(sin(fi * 12.9898) * 43758.5453)
            let ry = frac(sin(fi * 78.233) * 12345.678)
            let rz = frac(sin(fi * 39.346) * 24680.13)
            let base = SIMD3<Float>((rx - 0.5) * width * 0.8,
                                    padHeight + 0.004 + ry * (charH * 1.2 + 0.01),
                                    (rz - 0.5) * lowerH * 0.8)
            n.simdPosition = base
            floorFrame.addChildNode(n)
            particles.append((n, base, fi * 1.7))
        }

        // 雨衣ちゃん（公式MMDモデルを USDZ に変換したもの）。足を台座の上に載せ、下パネルの法線方向へ立たせる
        characterNode.removeAllActions()
        characterNode.geometry = nil
        characterNode.childNodes.forEach { $0.removeFromParentNode() }
        idleNode.childNodes.forEach { $0.removeFromParentNode() }
        if let model = loadModelOnce() {
            // モデルの実寸（約1.53m）を目標の高さへ縮小する。X・Z は中心、Y は足元を原点にそろえる
            let wrap = model.node
            let h = max(model.maxB.y - model.minB.y, Float(0.001))
            let s = charH / h
            let cx = (model.minB.x + model.maxB.x) / 2
            let cz = (model.minB.z + model.maxB.z) / 2
            wrap.scale = SCNVector3(s, s, s)
            wrap.position = SCNVector3(-cx * s, -model.minB.y * s, -cz * s)
            idleNode.addChildNode(wrap)
        } else {
            // モデルが読めないときの保険（従来の1枚絵プレーン）
            let plane = SCNPlane(width: CGFloat(charH) * 2 / 3, height: CGFloat(charH))
            let cm = SCNMaterial()
            cm.lightingModel = .constant
            cm.diffuse.contents = AmekoroTexture.load()
            cm.isDoubleSided = true
            cm.transparencyMode = .aOne
            plane.materials = [cm]
            let holder = SCNNode(geometry: plane)
            holder.position = SCNVector3(0, charH / 2, 0)
            idleNode.addChildNode(holder)
        }
        idleNode.removeFromParentNode()
        characterNode.addChildNode(idleNode)
        characterNode.position = SCNVector3(0, padHeight, 0)
        // 向きは正面固定（+z＝利用者側）。回り込むと横側が見える
        characterNode.eulerAngles = SCNVector3Zero
        floorFrame.addChildNode(characterNode)
        charBuilt = true
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

    /// 中心が濃く縁へ向けて消える、暗い半透明の円（接地影用）。
    private static func softDiscImage() -> UIImage {
        let size = CGSize(width: 128, height: 128)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.95).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(grad, startCenter: c, startRadius: 0,
                                             endCenter: c, endRadius: size.width / 2, options: [])
        }
    }

    /// 縦方向に濃→透明へ消える黒のグラデーション（部屋の角の暗がり用）。
    private static func cornerShadeImage(darkAtTop: Bool) -> UIImage {
        let size = CGSize(width: 4, height: 64)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 0, alpha: 0.55).cgColor, UIColor(white: 0, alpha: 0).cgColor] as CFArray
            guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
            let from = CGPoint(x: 0, y: darkAtTop ? 0 : size.height)
            let to = CGPoint(x: 0, y: darkAtTop ? size.height : 0)
            ctx.cgContext.drawLinearGradient(grad, start: from, end: to, options: [])
        }
    }

    // MARK: - 毎フレーム

    /// 視点・折り角度を平滑化し、床の枠と2つのカメラの投影を更新する。上半分の view の描画前に1回だけ呼ぶ。
    func update(time: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(time - lastTime, 0.1)
        lastTime = time
        let k = Float(1 - exp(-dt * 12))

        // 目の位置（上パネル座標＝折り目が原点）。
        // 顔が見えていれば、カメラ相対の目の位置にカメラの位置（機種プロファイル）を足す。
        // 見えていなければドラッグ（基準の目の位置からのずれ）。
        let target: SIMD3<Float>
        if let tracker, tracker.faceActive {
            let h = tracker.head
            target = SIMD3<Float>(profile.cameraRight + h.x, upperH + profile.cameraAboveTopEdge + h.y, h.z)
        } else {
            target = nominalEye + SIMD3<Float>(manual.x, manual.y, 0)
        }
        if !eyeInitialized { smoothedEye = target; eyeInitialized = true }
        smoothedEye += (target - smoothedEye) * k
        let eye = SIMD3<Float>(smoothedEye.x, smoothedEye.y, max(smoothedEye.z, 0.1))

        // 折り角度：取れなければ全開 180°（＝従来の単一平面）。ライブ更新に追従
        let angleTarget = Float(min(max(hinge?.radians ?? .pi, .pi / 6), .pi))
        smoothedAngle += (angleTarget - smoothedAngle) * k
        let th = smoothedAngle

        let lower = lowerPlane(angle: th)

        // 床の枠：下パネルの面に合わせる（x=右、y=法線、z=端へ向かう向き。右手系）。原点は下パネルの中央
        floorFrame.simdTransform = simd_float4x4(columns: (
            SIMD4(1, 0, 0, 0), SIMD4(lower.normal, 0), SIMD4(lower.d, 0), SIMD4(lower.center, 1)))

        // 床と壁の交線（部屋の角）。wallRecess = 0 なら折り目そのもの
        let recess = wallRecess
        let sC = -recess / max(sin(th), 0.2)        // 角の位置（折り目から d 方向への距離。負＝折り目の奥側）
        let yC = cos(th) * sC                       // 角の高さ（上パネル座標）
        let wallH = max(upperH + 0.3 - yC, 0.01)
        wallNode.simdPosition = SIMD3(0, yC + wallH / 2, -recess)
        wallNode.simdScale = SIMD3(1, wallH, 1)
        wallShade.simdPosition = SIMD3(0, yC + 0.015, -recess + 0.0003)
        // 床は角から下パネルの手前の端（＋2cm）まで
        let floorEnd = lowerH + 0.02
        let floorLen = max(floorEnd - sC, 0.01)
        floorNode.simdPosition = SIMD3(0, 0, (sC + floorEnd) / 2 - lowerH / 2)
        floorNode.simdScale = SIMD3(1, floorLen, 1)
        floorShade.simdPosition = SIMD3(0, 0.0003, sC + 0.015 - lowerH / 2)

        // 身長の倍率（検証用）。足元が原点なので足は動かない
        let hs = heightScale
        idleNode.simdScale = SIMD3(hs, hs, hs)

        // 上パネル：中心 (0, upperH/2, 0)、右 +x、上 +y
        _ = setProjection(camera: upperCamera, eye: eye,
                          center: SIMD3(0, upperH / 2, 0),
                          right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0),
                          halfW: width / 2, halfH: upperH / 2)
        // 下パネル：同じ目・同じ世界座標系・同じ関数。上は折り目へ向かう向き（-d）
        lowerValid = setProjection(camera: lowerCamera, eye: eye,
                                   center: lower.center,
                                   right: SIMD3(1, 0, 0), up: lower.up,
                                   halfW: width / 2, halfH: lowerH / 2)

        updateIdle(time: Float(time.truncatingRemainder(dividingBy: 3600)))

        snapLock.lock()
        _snap = Snapshot(eye: eye, angleDeg: th * 180 / .pi,
                         charHeightMM: baseCharHeight * hs * 1000,
                         lowerEyeHeightMM: simd_dot(eye - lower.center, lower.normal) * 1000,
                         lowerValid: lowerValid)
        snapLock.unlock()
    }

    /// アイドル演出：微粒子だけ残す（浮遊・傾き・呼吸・フリッカー・走査線は止めた）。
    private func updateIdle(time t: Float) {
        guard charBuilt else { return }
        for p in particles {
            let ph = p.phase
            p.node.simdPosition = p.base + SIMD3<Float>(0.003 * sin(t * 0.5 + ph),
                                                        0.004 * sin(t * 0.35 + ph * 1.3),
                                                        0.002 * sin(t * 0.42 + ph * 0.7))
            p.node.opacity = CGFloat(0.35 + 0.35 * sin(t * 0.9 + ph))
        }
    }

    /// Kooima の generalized perspective projection。1枚の物理的な窓（中心・右・上・半幅・半高）と目の位置から、
    /// 窓を通した off-axis 錐台を作ってカメラへ設定する。上下どちらの窓も、この同じ関数を同じ世界座標で呼ぶ。
    /// カメラは目の位置に置き、向きは窓に揃える（傾けず錐台を非対称にする）。
    /// 目が窓の裏側（または窓とほぼ同一平面）で成り立たないときは false を返し、カメラは変更しない。
    private func setProjection(camera node: SCNNode, eye pe: SIMD3<Float>,
                               center: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                               halfW: Float, halfH: Float) -> Bool {
        // 窓の角3点：左下 pa、右下 pb、左上 pc
        let pa = center - right * halfW - up * halfH
        let pb = center + right * halfW - up * halfH
        let pc = center - right * halfW + up * halfH
        // 窓の正規直交基底（vn は窓から目の側へ向く法線）
        let vr = simd_normalize(pb - pa)
        let vu = simd_normalize(pc - pa)
        let vn = simd_normalize(simd_cross(vr, vu))
        // 目から各角へのベクトルと、窓までの距離
        let va = pa - pe, vb = pb - pe, vc = pc - pe
        let dist = -simd_dot(va, vn)
        guard dist > 0.02 else { return false }

        let near: Float = 0.01, far: Float = 2.0
        let l = simd_dot(vr, va) * near / dist
        let r = simd_dot(vr, vb) * near / dist
        let b = simd_dot(vu, va) * near / dist
        let t = simd_dot(vu, vc) * near / dist

        var m = SCNMatrix4Identity
        m.m11 = 2 * near / (r - l)
        m.m22 = 2 * near / (t - b)
        m.m31 = (r + l) / (r - l)
        m.m32 = (t + b) / (t - b)
        m.m33 = -(far + near) / (far - near)
        m.m34 = -1
        m.m43 = -2 * far * near / (far - near)
        m.m44 = 0

        // カメラの軸 = 窓の (右, 上, 法線)。カメラは -法線 方向（画面の奥）を見る
        node.simdTransform = simd_float4x4(columns: (
            SIMD4(vr, 0), SIMD4(vu, 0), SIMD4(vn, 0), SIMD4(pe, 1)))
        node.camera?.projectionTransform = m
        return true
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
    var diagnostics: HologramDiagnostics? {
        didSet {
            guard let diagnostics else { return }
            diagnostics.rig = rig
            // 計測パネルの調整値を描画側へ流す
            cancellables.removeAll()
            diagnostics.$wallRecessMM.sink { [weak self] v in self?.rig.setWallRecess(Float(v) / 1000) }
                .store(in: &cancellables)
            diagnostics.$heightScale.sink { [weak self] v in self?.rig.setHeightScale(Float(v)) }
                .store(in: &cancellables)
        }
    }
    private var cancellables = Set<AnyCancellable>()
    private var lastLowerOK = true
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

        // ポイント → メートル。機種プロファイルの実寸（未実測なら短辺 65mm の近似）。上下で同じ尺度を使う
        let profile = HologramDeviceProfile.current()
        rig.profile = profile
        let mpp = profile.metersPerPoint(boundsShortSide: min(bounds.width, bounds.height))
        rig.configure(width: Float(bounds.width) * mpp,
                      upperH: Float(fold) * mpp,
                      lowerH: Float(bounds.height - fold) * mpp)

        // 計測パネルへ：折り目のY位置（取れなければ nil）、材質の数
        let reportedFold: CGFloat? = hinge?.foldY(in: self)
        let found = rig.materialFound, total = rig.materialTotal
        let mppValue = mpp
        DispatchQueue.main.async { [weak self] in
            guard let d = self?.diagnostics else { return }
            d.foldY = reportedFold
            d.profileID = profile.machineID
            d.profileIsFallback = profile.isFallback
            d.mmPerPt = Double(mppValue) * 1000
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
        // 目が下パネルの裏側に回って投影が成り立たないときは、ゆがんだ絵を出さず下のビューを隠す
        let ok = rig.lowerValid
        if ok != lastLowerOK {
            lastLowerOK = ok
            DispatchQueue.main.async { [weak self] in self?.lowerView.isHidden = !ok }
        }
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
