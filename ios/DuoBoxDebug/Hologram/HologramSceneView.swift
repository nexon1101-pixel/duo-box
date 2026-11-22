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

    /// モデルの正面が floorFrame の +z（+d）を向くための y 回転。モデル正面は +Z なので 0
    static let modelFrontYaw: Float = 0

    private var width: Float = 0.065
    private var upperH: Float = 0.07
    private var lowerH: Float = 0.07
    private var builtFor = SIMD3<Float>(0, 0, 0)

    // 調整値（メインスレッドで書き、描画スレッドで読む）
    private let tuneLock = NSLock()
    private var _wallRecess: Float = 0.030  // 壁を奥へ下げる量（m、初期値 30mm。パネル側の初期値と一致させる）
    private var _heightScale: Float = 1     // 身長の倍率（検証用）
    func setWallRecess(_ v: Float) { tuneLock.lock(); _wallRecess = max(v, 0); tuneLock.unlock() }
    func setHeightScale(_ v: Float) { tuneLock.lock(); _heightScale = max(v, 0.1); tuneLock.unlock() }
    private var _pPos: Float = 0.5          // 前後位置 p（0＝下パネルの手前の端、1＝折り目、1超＝床の角まで）
    func setPPos(_ v: Float) { tuneLock.lock(); _pPos = max(v, 0); tuneLock.unlock() }
    private var pPos: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _pPos }
    private var _wAuto: Bool = true          // 向き w を角度で自動にするか（既定は自動）
    func setWAuto(_ v: Bool) { tuneLock.lock(); _wAuto = v; tuneLock.unlock() }
    private var wAuto: Bool { tuneLock.lock(); defer { tuneLock.unlock() }; return _wAuto }
    private var _wLean: Float = 0            // 手動の w（0＝床の法線どおり、1＝真上）
    func setWLean(_ v: Float) { tuneLock.lock(); _wLean = min(max(v, 0), 1); tuneLock.unlock() }
    private var wLean: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _wLean }
    private var _oeMinCutoff: Float = 1.2    // 1€ 最小カットオフ (Hz)
    func setOneEuroMinCutoff(_ v: Float) { tuneLock.lock(); _oeMinCutoff = min(max(v, 0.05), 10); tuneLock.unlock() }
    private var oeMinCutoff: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _oeMinCutoff }
    private var _oeBeta: Float = 0.8         // 1€ 速度係数（速く動くほどカットオフを上げる）
    func setOneEuroBeta(_ v: Float) { tuneLock.lock(); _oeBeta = min(max(v, 0), 5); tuneLock.unlock() }
    private var oeBeta: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _oeBeta }
    private var _oePred: Float = 0.02        // 先読み時間 (秒)
    func setOneEuroPred(_ v: Float) { tuneLock.lock(); _oePred = min(max(v, 0), 0.08); tuneLock.unlock() }
    private var oePred: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _oePred }
    private var _pAuto: Bool = true          // 前後位置 p を角度で自動にするか（既定は自動）
    func setPAuto(_ v: Bool) { tuneLock.lock(); _pAuto = v; tuneLock.unlock() }
    private var pAuto: Bool { tuneLock.lock(); defer { tuneLock.unlock() }; return _pAuto }
    private var _pwTable: [(angle: Float, p: Float, w: Float)] = []   // 角度ごとの p・w 記録（角度の昇順）
    func setPWTable(_ t: [(angle: Float, p: Float, w: Float)]) { tuneLock.lock(); _pwTable = t; tuneLock.unlock() }
    private var pwTable: [(angle: Float, p: Float, w: Float)] { tuneLock.lock(); defer { tuneLock.unlock() }; return _pwTable }

    /// 記録表から角度に対する p・w を線形補間する。表が空、または角度が記録の範囲外なら nil
    private func pwInterp(angleDeg: Float) -> (p: Float, w: Float)? {
        let t = pwTable
        guard let first = t.first, let last = t.last,
              angleDeg >= first.angle, angleDeg <= last.angle else { return nil }
        if t.count == 1 { return (first.p, first.w) }
        for i in 0..<(t.count - 1) {
            let a = t[i], b = t[i + 1]
            if angleDeg >= a.angle && angleDeg <= b.angle {
                let f = b.angle > a.angle ? (angleDeg - a.angle) / (b.angle - a.angle) : 0
                return (a.p + (b.p - a.p) * f, a.w + (b.w - a.w) * f)
            }
        }
        return nil
    }
    private var _showMarkers = false        // 位置合わせマーカーの表示
    func setShowMarkers(_ v: Bool) { tuneLock.lock(); _showMarkers = v; tuneLock.unlock() }
    private var showMarkers: Bool { tuneLock.lock(); defer { tuneLock.unlock() }; return _showMarkers }
    private var _showGrid = true            // 格子（床と壁）の表示
    func setShowGrid(_ v: Bool) { tuneLock.lock(); _showGrid = v; tuneLock.unlock() }
    private var showGrid: Bool { tuneLock.lock(); defer { tuneLock.unlock() }; return _showGrid }
    private var wallRecess: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _wallRecess }
    private var heightScale: Float { tuneLock.lock(); defer { tuneLock.unlock() }; return _heightScale }

    private let worldNode = SCNNode()       // 壁と、壁側の暗がり
    private let floorFrame = SCNNode()      // 下パネルの面に合わせる枠（床・台座・影・キャラの親）
    private let standNode = SCNNode()       // キャラ・台座・影・微粒子の親。床の奥行き方向へ動かす
    private let characterNode = SCNNode()
    private let baseboardNode = SCNNode()   // 壁の根元の細いライン
    private let wallFrameNode = SCNNode()   // 壁の淡い矩形の枠（彼女の背後）
    private var wallFrameH: Float = 0.05
    private var floorLines: [(node: SCNNode, frac: Float)] = []   // 折り目と平行な床の淡いライン
    private let idleNode = SCNNode()
    private let shadowNode = SCNNode()
    private let padNode = SCNNode()         // 台座の円盤・リング・影（身長倍率に合わせて水平方向だけ拡縮）
    private let wallNode = SCNNode()
    private let floorNode = SCNNode()
    private let wallShade = SCNNode()
    private let floorShade = SCNNode()
    private var particles: [(node: SCNNode, base: SIMD3<Float>, phase: Float)] = []
    private var markerNodes: [SCNNode] = []   // 位置合わせマーカー（rebuildWorld で作り直す）
    // 格子：部屋の角を原点に gridStep 間隔で引く細線。位置は update() で毎フレーム角に合わせる
    private let gridStep: Float = 0.02
    private var gridWallH: [(node: SCNNode, k: Float)] = []
    private var gridWallV: [(node: SCNNode, k: Float)] = []
    private var gridFloorH: [(node: SCNNode, k: Float)] = []
    private var gridFloorV: [(node: SCNNode, k: Float)] = []
    private var charBuilt = false

    /// 既定の身長（m）。下パネル奥行き lowerH と同じ
    private(set) var baseCharHeight: Float = 0.04
    private let padHeight: Float = 0.002    // 台座の厚み（キャラの足はこの上）

    /// 読み込み済みのモデル（USDZ は 41MB あるので1回だけ読む。折り目が変わっても読み直さない）
    private var cachedModel: (node: SCNNode, minB: SCNVector3, maxB: SCNVector3)?
    private var modelLoadTried = false
    /// 材質名で見つかった修正対象の数と、モデルの材質の総数（計測パネル用）
    private(set) var materialFound = 0
    private(set) var materialTotal = 0

    /// 1€ フィルタ（Casiez et al., CHI 2012）：速度でカットオフが変わるローパス。
    /// 静止時は強くなめらかに、速く動くほど追従する。dxHat が先読みに使う速度になる
    private struct OneEuro3 {
        var xHat = SIMD3<Float>(0, 0, 0)
        var dxHat = SIMD3<Float>(0, 0, 0)
        private var prevX = SIMD3<Float>(0, 0, 0)
        private var initialized = false

        mutating func filter(_ x: SIMD3<Float>, dt: Float, minCutoff: Float, beta: Float, dCutoff: Float) -> SIMD3<Float> {
            let dtc = max(dt, 0.001)
            if !initialized { xHat = x; prevX = x; initialized = true; return x }
            let dx = (x - prevX) / dtc
            prevX = x
            dxHat += (dx - dxHat) * Self.alpha(cutoff: dCutoff, dt: dtc)
            for i in 0..<3 {
                let cutoff = minCutoff + beta * abs(dxHat[i])
                xHat[i] += (x[i] - xHat[i]) * Self.alpha(cutoff: cutoff, dt: dtc)
            }
            return xHat
        }

        private static func alpha(cutoff: Float, dt: Float) -> Float {
            let tau = 1 / (2 * Float.pi * max(cutoff, 0.01))
            return 1 / (1 + tau / dt)
        }
    }

    private var eyeFilter = OneEuro3()
    private var smoothedAngle: Float = .pi     // 全開 180° から始める
    private var lastTime: TimeInterval = 0
    /// 顔ロスト時の保持用：最後に顔で決まった目の目標と、ロストが始まった時刻
    private var lastFaceTarget: SIMD3<Float>?
    private var faceLostSince: TimeInterval?

    /// 下パネルの投影が成り立っているか（目が裏側に回ると false）。描画スレッドで更新
    private(set) var lowerValid = true

    /// 計測パネル用の値
    struct Snapshot {
        var eye = SIMD3<Float>(0, 0, 0)
        var angleDeg: Float = 180
        var charHeightMM: Float = 0
        var autoHeightMM: Float = 0
        var pEff: Float = 0.5
        var padPct: Float = 100
        var wEff: Float = 0
        var lowerEyeHeightMM: Float = 0
        var lowerValid = true
        var marginUpperMM: [Float] = []   // 見切れ余裕（上パネル、mm）。並びは [頭, 足, 台座の縁, 体の左右, 1/4, 1/2, 3/4]、数えられない点は NaN
        var marginLowerMM: [Float] = []   // 見切れ余裕（下パネル、mm）
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
    /// ただし 0.2mm 未満の変化では作り直さない（折り目位置の微振動で全体が再構築されるのを防ぐ歯止め）。
    func configure(width: Float, upperH: Float, lowerH: Float) {
        self.width = width; self.upperH = upperH; self.lowerH = lowerH
        let key = SIMD3(width, upperH, lowerH)
        if key != builtFor {
            let d = abs(key - builtFor)
            if d.x < 0.0002 && d.y < 0.0002 && d.z < 0.0002 { return }
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

    /// ビルド時の基準身長（モデルの拡縮の基準値）。実際の身長は update() で自動決定する
    private func defaultCharHeight() -> Float { lowerH * 1.0 }

    /// 点 P を目 E から見たときの「見切れ余裕」（m）。
    /// 窓ごとに、点がその窓の側にあるときだけ数える：上パネルは交点 y≧0 のとき上端と左右、
    /// 下パネルは交点の折り目からの距離 v≧0 のとき手前の端と左右までの余裕の最小値。
    /// 両方の窓で数えられる場合は大きい方（実際に見えている側）を採用。数えられなければ nil。
    private func windowMargins(_ P: SIMD3<Float>, eye E: SIMD3<Float>,
                               d: SIMD3<Float>, n: SIMD3<Float>) -> (upper: Float?, lower: Float?) {
        var upper: Float? = nil
        let dz = E.z - P.z
        if dz > 1e-6 {
            let q = E + (P - E) * (E.z / dz)              // 上パネル面（z=0）との交点
            if q.y >= 0 { upper = min(upperH - q.y, q.x + width / 2, width / 2 - q.x) }
        }
        var lower: Float? = nil
        let denom = simd_dot(P - E, n)
        if abs(denom) > 1e-9 {
            let t = simd_dot(-E, n) / denom
            if t > 0 {
                let q = E + (P - E) * t                   // 下パネル面との交点
                let v = simd_dot(q, d)                    // 折り目からの距離
                if v >= 0 { lower = min(lowerH - v, q.x + width / 2, width / 2 - q.x) }
            }
        }
        return (upper, lower)
    }

    /// 窓ごとの余裕のうち、実際に見えている側（大きい方）だけを返す
    private func windowMargin(_ P: SIMD3<Float>, eye E: SIMD3<Float>,
                              d: SIMD3<Float>, n: SIMD3<Float>) -> Float? {
        let m = windowMargins(P, eye: E, d: d, n: n)
        switch (m.upper, m.lower) {
        case let (u?, l?): return max(u, l)
        case let (u?, nil): return u
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    /// 身長の自動決定：既定は 0.6 × min(上パネル高, 下パネル高)。
    /// 目の位置が箱（x ±6cm、y 3〜22cm、z 25〜45cm）のどこにあっても、
    /// 頭・体の左右・1/4・1/2・3/4 の点と台座の縁の余裕が 8mm 未満になる場合は、その分だけ小さくする。
    /// 折り角・立ち位置・向きが変わると結果も変わるので、update() から毎フレーム呼ぶ。
    private func fittedHeight(stand S: SIMD3<Float>, up u: SIMD3<Float>,
                              d: SIMD3<Float>, n: SIMD3<Float>, eye: SIMD3<Float>) -> Float {
        let target = 0.6 * min(upperH, lowerH)
        let base = S + n * padHeight                       // 足の位置（台座の上面）
        var eyes: [SIMD3<Float>] = [eye]
        for x in [Float(-0.06), 0, 0.06] { for y in [Float(0.03), 0.125, 0.22] { for z in [Float(0.25), 0.45] {
            eyes.append(SIMD3<Float>(x, y, z))
        } } }
        func minMargin(_ h: Float) -> Float {
            let r = h * 0.32
            let pts: [SIMD3<Float>] = [
                base + u * h, base + u * (h * 0.25), base + u * (h * 0.5), base + u * (h * 0.75),
                base + u * (h * 0.5) + SIMD3(0.15 * h, 0, 0), base + u * (h * 0.5) - SIMD3(0.15 * h, 0, 0),
                S + SIMD3(r, 0, 0), S - SIMD3(r, 0, 0), S + d * r, S - d * r]
            var m: Float = .greatestFiniteMagnitude
            for e in eyes { for p in pts {
                if let w = windowMargin(p, eye: e, d: d, n: n) { m = min(m, w) }
            } }
            return m
        }
        if minMargin(target) >= 0.008 { return target }
        var lo: Float = 0.01, hi = target
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if minMargin(mid) >= 0.008 { lo = mid } else { hi = mid }
        }
        return lo
    }

    // MARK: - シーン構築

    private func rebuildWorld() {
        worldNode.childNodes.forEach { $0.removeFromParentNode() }
        floorFrame.childNodes.forEach { $0.removeFromParentNode() }
        standNode.childNodes.forEach { $0.removeFromParentNode() }
        floorLines.removeAll()
        markerNodes.removeAll()
        gridWallH.removeAll(); gridWallV.removeAll(); gridFloorH.removeAll(); gridFloorV.removeAll()
        let w = CGFloat(width)

        baseCharHeight = defaultCharHeight()
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

        // 部屋の奥行きの手がかり（控えめ：壁・床より少し明るい程度の無発光の細線だけ）
        func lineMaterial(_ c: UIColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = c
            m.isDoubleSided = true
            return m
        }
        // ① 巾木：壁の根元に沿った細いライン
        baseboardNode.removeFromParentNode()
        let baseboard = SCNPlane(width: w * 3, height: 0.004)
        baseboard.materials = [lineMaterial(UIColor(red: 0.29, green: 0.32, blue: 0.41, alpha: 1))]
        baseboardNode.geometry = baseboard
        worldNode.addChildNode(baseboardNode)
        // ② 床の淡いライン：折り目と平行、実寸で等間隔（遠近法で奥ほど詰まって見える）。角からの奥行き比 0.3 / 0.55 / 0.8
        for f: Float in [0.3, 0.55, 0.8] {
            let plane = SCNPlane(width: w * 3, height: 0.0012)
            plane.materials = [lineMaterial(UIColor(red: 0.23, green: 0.25, blue: 0.32, alpha: 1))]
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -.pi / 2
            n.renderingOrder = 1
            floorFrame.addChildNode(n)
            floorLines.append((n, f))
        }
        // ③ 壁の矩形の枠：彼女の背後。キャラより一回り大きい（上パネルに収まる範囲）
        wallFrameNode.removeFromParentNode()
        wallFrameNode.childNodes.forEach { $0.removeFromParentNode() }
        let fh = min(charH * 1.2, upperH * 0.8)
        let fw = fh * 0.62
        wallFrameH = fh
        let t: Float = 0.0015
        let frameMat = lineMaterial(UIColor(red: 0.30, green: 0.33, blue: 0.43, alpha: 1))
        let fillMat = lineMaterial(UIColor(red: 0.235, green: 0.255, blue: 0.335, alpha: 1))
        let fill = SCNNode(geometry: SCNPlane(width: CGFloat(fw), height: CGFloat(fh)))
        fill.geometry?.materials = [fillMat]
        wallFrameNode.addChildNode(fill)
        let edges: [(CGFloat, CGFloat, Float, Float)] = [
            (CGFloat(fw), CGFloat(t), 0, fh / 2), (CGFloat(fw), CGFloat(t), 0, -fh / 2),
            (CGFloat(t), CGFloat(fh), -fw / 2, 0), (CGFloat(t), CGFloat(fh), fw / 2, 0)]
        for (ew, eh, ex, ey) in edges {
            let plane = SCNPlane(width: ew, height: eh)
            plane.materials = [frameMat]
            let n = SCNNode(geometry: plane)
            n.position = SCNVector3(ex, ey, 0.0002)
            wallFrameNode.addChildNode(n)
        }
        worldNode.addChildNode(wallFrameNode)

        // 位置合わせマーカー：物理的な画面の角・折り目に対応する点。壁の凹み（wallRecess）には付けず、
        // 画面の面そのもの（上パネルは z=0、下パネルは floorFrame の面）に置く。
        // 投影・寸法・カメラ位置が合っていれば、頭を動かしても画面の角に張り付いて見える。
        func marker(_ color: UIColor) -> SCNNode {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            let s = SCNSphere(radius: 0.0028)
            s.materials = [m]
            let n = SCNNode(geometry: s)
            n.isHidden = true
            n.renderingOrder = 5
            markerNodes.append(n)
            return n
        }
        let hw = width / 2
        for x in [-hw, hw] {
            let top = marker(.cyan)              // 上パネルの角
            top.simdPosition = SIMD3(x, upperH, 0.0012)
            worldNode.addChildNode(top)
            let fold = marker(.yellow)           // 折り目の端
            fold.simdPosition = SIMD3(x, 0, 0.0012)
            worldNode.addChildNode(fold)
        }
        let foldCenter = marker(.yellow)         // 折り目の中央（上下の段差チェック用）
        foldCenter.simdPosition = SIMD3(0, 0, 0.0012)
        worldNode.addChildNode(foldCenter)

        // 格子：床と壁に 20mm 間隔の細線。部屋の角を原点にするので、折り目で床と壁の線がつながる。
        // 位置と長さは折り角と wallRecess で変わるため、update() で毎フレーム合わせる（ここでは形だけ作る）
        let gridWallMat = lineMaterial(UIColor(red: 0.32, green: 0.35, blue: 0.45, alpha: 1))
        let gridFloorMat = lineMaterial(UIColor(red: 0.26, green: 0.28, blue: 0.36, alpha: 1))
        for k in 1...24 {                        // 壁の横線（角から上へ）
            let p = SCNPlane(width: w * 3, height: 0.0009)
            p.materials = [gridWallMat]
            let n = SCNNode(geometry: p)
            n.renderingOrder = 1
            worldNode.addChildNode(n)
            gridWallH.append((n, Float(k)))
        }
        for k in -10...10 {                      // 壁の縦線
            let p = SCNPlane(width: 0.0009, height: 1)
            p.materials = [gridWallMat]
            let n = SCNNode(geometry: p)
            n.renderingOrder = 1
            worldNode.addChildNode(n)
            gridWallV.append((n, Float(k)))
        }
        for k in 1...10 {                        // 床の横線（角から手前へ、折り目と平行）
            let p = SCNPlane(width: w * 3, height: 0.0012)
            p.materials = [gridFloorMat]
            let n = SCNNode(geometry: p)
            n.eulerAngles.x = -.pi / 2
            n.renderingOrder = 1
            floorFrame.addChildNode(n)
            gridFloorH.append((n, Float(k)))
        }
        for k in -10...10 {                      // 床の縦線（奥行き方向）
            let p = SCNPlane(width: 0.0009, height: 1)
            p.materials = [gridFloorMat]
            let n = SCNNode(geometry: p)
            n.eulerAngles.x = -.pi / 2
            n.renderingOrder = 1
            floorFrame.addChildNode(n)
            gridFloorV.append((n, Float(k)))
        }
        for x in [-hw, hw] {
            for z in [-lowerH / 2, lowerH / 2] {  // 下パネルの四隅（floorFrame 局所：原点は中央、z+ が手前の端）
                let n = marker(.magenta)
                n.simdPosition = SIMD3(x, 0.0015, z)
                floorFrame.addChildNode(n)
            }
        }

        standNode.removeFromParentNode()
        floorFrame.addChildNode(standNode)
        padNode.removeFromParentNode()
        padNode.childNodes.forEach { $0.removeFromParentNode() }
        standNode.addChildNode(padNode)
        // 台座：低い円盤＋細いリング1本（明滅なし）。floorFrame の原点＝下パネルの中央
        let radius = max(CGFloat(charH) * 0.32, 0.008)   // 身長の約0.32倍。倍率スライダーには padNode のスケールで追従
        let disc = SCNCylinder(radius: radius, height: CGFloat(padHeight))
        let discMat = SCNMaterial()
        discMat.lightingModel = .constant
        discMat.diffuse.contents = UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1)
        disc.materials = [discMat]
        let pad = SCNNode(geometry: disc)
        pad.position = SCNVector3(0, padHeight / 2, 0)
        padNode.addChildNode(pad)

        let ring = SCNTorus(ringRadius: radius, pipeRadius: 0.0006)
        let ringMat = SCNMaterial()
        ringMat.lightingModel = .constant
        ringMat.diffuse.contents = UIColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1)   // リボンの青
        ring.materials = [ringMat]
        let ringNode = SCNNode(geometry: ring)
        ringNode.position = SCNVector3(0, padHeight + 0.0004, 0)
        padNode.addChildNode(ringNode)

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
        padNode.addChildNode(shadowNode)

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
            let base = SIMD3<Float>((rx - 0.5) * width * 0.7,
                                    padHeight + 0.004 + ry * (charH * 1.2 + 0.01),
                                    (rz - 0.5) * lowerH * 0.5)   // standNode の局所座標（キャラのまわり）
            n.simdPosition = base
            standNode.addChildNode(n)
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
        // 向き：floorFrame の +z（＝下パネルの折り目から手前の端へ向かう +d）へ正面を向ける。
        // モデルの正面は +Z（ビルド75〜79で atan2(dx,dz) により +Z を視点へ向けて正面が見えていた／Blender系USD出力は前方 -Y→+Z）。
        // 向きが逆なら modelFrontYaw を .pi にする
        characterNode.eulerAngles = SCNVector3(0, Self.modelFrontYaw, 0)
        standNode.addChildNode(characterNode)
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
            // 絶対位置のみ（手順4）：目の位置 = カメラの位置（機種プロファイル）+ 軸対応を適用した目位置。
            // ホーム基準と視差ゲインは廃止。目の絶対位置のずれは機種プロファイル側で吸収する。
            let camOffset = SIMD3<Float>(profile.cameraRight, upperH + profile.cameraAboveTopEdge, 0)
            target = camOffset + tracker.mappedHead
            lastFaceTarget = target
            faceLostSince = nil
        } else if let last = lastFaceTarget {
            // 顔が見えなくなったら基準へ即座に戻さず、最後の位置を 1.5 秒保ち、
            // その後 2.5 秒かけて基準の目の位置へゆっくり戻す。戻り切ったら保持を解く。
            if faceLostSince == nil { faceLostSince = time }
            let lost = time - (faceLostSince ?? time)
            if lost <= 1.5 {
                target = last + SIMD3<Float>(manual.x, manual.y, 0)
            } else {
                let f = min(Float((lost - 1.5) / 2.5), 1)
                target = nominalEye + (last - nominalEye) * (1 - f) + SIMD3<Float>(manual.x, manual.y, 0)
                if f >= 1 { lastFaceTarget = nil; faceLostSince = nil }
            }
        } else {
            target = nominalEye + SIMD3<Float>(manual.x, manual.y, 0)
        }
        // 平滑化は 1€ フィルタ（手順5）。さらに速度×先読み時間だけ先の位置を出して表示までの遅れを埋める
        let filtered = eyeFilter.filter(target, dt: Float(dt), minCutoff: oeMinCutoff, beta: oeBeta, dCutoff: 1.0)
        let predicted = filtered + eyeFilter.dxHat * oePred
        let eye = SIMD3<Float>(predicted.x, predicted.y, max(predicted.z, 0.1))

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

        // 立ち位置：p（0＝手前の端、1＝折り目、1超は床の角まで）を、折り目からの距離へ直して置く
        let floorDepth = max(lowerH - sC, 0.01)
        let pMax = 1 + (-sC) / lowerH
        let angleDegNow = th * 180 / .pi
        let pwNow = pwInterp(angleDeg: angleDegNow)
        let pBase = pAuto ? (pwNow?.p ?? 0.5) : pPos
        let pEff = min(max(pBase, 0), pMax)
        let distFold = (1 - pEff) * lowerH    // 折り目から手前方向への距離（負＝折り目より奥）
        standNode.simdPosition = SIMD3(0, 0, distFold - lowerH / 2)
        // 部屋の手がかり：巾木・床のライン・壁の枠
        baseboardNode.simdPosition = SIMD3(0, yC + 0.002, -recess + 0.0004)
        for l in floorLines {
            l.node.simdPosition = SIMD3(0, 0.0002, sC - lowerH / 2 + l.frac * floorDepth)
        }
        let frameBottom = yC + max(upperH * 0.06, 0.006)
        wallFrameNode.simdPosition = SIMD3(0, frameBottom + wallFrameH / 2, -recess + 0.0005)

        // 位置合わせマーカーの表示切り替え（パネルのトグル）
        let sm = showMarkers
        for n in markerNodes where n.isHidden == sm { n.isHidden = !sm }

        // 格子：部屋の角（壁側は yC、床側は sC）を原点に等間隔で並べる。角を共有するので折り目でつながる
        let gs = showGrid
        for g in gridWallH {
            g.node.simdPosition = SIMD3(0, yC + g.k * gridStep, -recess + 0.0006)
            g.node.isHidden = !gs
        }
        for g in gridWallV {
            g.node.simdPosition = SIMD3(g.k * gridStep, yC + wallH / 2, -recess + 0.0006)
            g.node.simdScale = SIMD3(1, wallH, 1)
            g.node.isHidden = !gs
        }
        for g in gridFloorH {
            g.node.simdPosition = SIMD3(0, 0.0002, sC - lowerH / 2 + g.k * gridStep)
            g.node.isHidden = !gs
        }
        for g in gridFloorV {
            g.node.simdPosition = SIMD3(g.k * gridStep, 0.0002, (sC + floorEnd) / 2 - lowerH / 2)
            g.node.simdScale = SIMD3(1, floorLen, 1)
            g.node.isHidden = !gs
        }

        // 向き w：自動なら、記録表があればその補間、なければ角度の smoothstep（110°で 0、170°で 1）。手動ならスライダーの値
        let wEff: Float
        if wAuto {
            if let pw = pwNow { wEff = pw.w }
            else {
                let tw = min(max((angleDegNow - 110) / 60, 0), 1)
                wEff = tw * tw * (3 - 2 * tw)
            }
        } else { wEff = wLean }
        // キャラの上方向 u（床の法線から真上へ w だけ寄せる）。台座は床のまま、キャラだけ傾ける。足は台座の中心のまま
        let upW = simd_normalize(lower.normal * (1 - wEff) + SIMD3<Float>(0, 1, 0) * wEff)
        let tiltA = atan2(wEff * cos(th), (1 - wEff) + wEff * sin(th))
        characterNode.simdOrientation = simd_quatf(angle: tiltA, axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: Self.modelFrontYaw, axis: SIMD3<Float>(0, 1, 0))

        // 身長は自動決定（0.6×小さい方のパネル高が既定、余裕 8mm を切る分だけ縮小）。手動の倍率はその上に掛かる
        let standWorld = lower.center + lower.d * standNode.simdPosition.z
        let autoH = fittedHeight(stand: standWorld, up: upW, d: lower.d, n: lower.normal, eye: eye)
        let hs = baseCharHeight > 0.001 ? (autoH * heightScale) / baseCharHeight : 1
        idleNode.simdScale = SIMD3(hs, hs, hs)
        padNode.simdScale = SIMD3(hs, 1, hs)   // 台座の半径も身長に連動（厚みは変えない）

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

        // 台座の円が下パネルの範囲に入っている割合（面積%）。幅方向は円が収まる前提で、折り目と手前端の2辺だけで計算する
        let padR = baseCharHeight * hs * 0.32
        let padPct: Float
        if padR > 0.0005 {
            func cap(_ r: Float, _ dist: Float) -> Float {   // 中心から dist 離れた直線の向こう側の欠け
                if dist >= r { return 0 }
                if dist <= -r { return .pi * r * r }
                return r * r * acos(dist / r) - dist * sqrt(max(r * r - dist * dist, 0))
            }
            padPct = (1 - (cap(padR, distFold) + cap(padR, lowerH - distFold)) / (.pi * padR * padR)) * 100
        } else { padPct = (distFold >= 0 && distFold <= lowerH) ? 100 : 0 }

        // 見切れ余裕（表示用）：いまの目の位置で各点を窓へ投影した余裕（mm、数えられない窓は NaN）
        let effH = baseCharHeight * hs
        let baseP = standWorld + lower.normal * padHeight
        let rimR = effH * 0.32
        let marginGroups: [[SIMD3<Float>]] = [
            [baseP + upW * effH],                                            // 頭
            [baseP],                                                         // 足
            [standWorld + SIMD3(rimR, 0, 0), standWorld - SIMD3(rimR, 0, 0),
             standWorld + lower.d * rimR, standWorld - lower.d * rimR],      // 台座の縁
            [baseP + upW * (effH * 0.5) + SIMD3(0.15 * effH, 0, 0),
             baseP + upW * (effH * 0.5) - SIMD3(0.15 * effH, 0, 0)],         // 体の左右
            [baseP + upW * (effH * 0.25)],                                   // 高さ 1/4
            [baseP + upW * (effH * 0.5)],                                    // 高さ 1/2
            [baseP + upW * (effH * 0.75)],                                   // 高さ 3/4
        ]
        var marginUpperMM: [Float] = []
        var marginLowerMM: [Float] = []
        for g in marginGroups {
            var u: Float? = nil, l: Float? = nil
            for p in g {
                let m = windowMargins(p, eye: eye, d: lower.d, n: lower.normal)
                if let v = m.upper { u = u.map { min($0, v) } ?? v }
                if let v = m.lower { l = l.map { min($0, v) } ?? v }
            }
            marginUpperMM.append((u ?? .nan) * 1000)
            marginLowerMM.append((l ?? .nan) * 1000)
        }

        snapLock.lock()
        _snap = Snapshot(eye: eye, angleDeg: th * 180 / .pi,
                         charHeightMM: baseCharHeight * hs * 1000,
                         autoHeightMM: autoH * 1000,
                         pEff: pEff, padPct: padPct, wEff: wEff,
                         lowerEyeHeightMM: simd_dot(eye - lower.center, lower.normal) * 1000,
                         lowerValid: lowerValid,
                         marginUpperMM: marginUpperMM, marginLowerMM: marginLowerMM)
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
            diagnostics.$pPos.sink { [weak self] v in self?.rig.setPPos(Float(v)) }
            diagnostics.$wAuto.sink { [weak self] v in self?.rig.setWAuto(v) }
            diagnostics.$wLean.sink { [weak self] v in self?.rig.setWLean(Float(v)) }
            diagnostics.$oeMinCutoff.sink { [weak self] v in self?.rig.setOneEuroMinCutoff(Float(v)) }
            diagnostics.$oeBeta.sink { [weak self] v in self?.rig.setOneEuroBeta(Float(v)) }
            diagnostics.$oePredMS.sink { [weak self] v in self?.rig.setOneEuroPred(Float(v) / 1000) }
            diagnostics.$pAuto.sink { [weak self] v in self?.rig.setPAuto(v) }
            diagnostics.$pwRecords.sink { [weak self] recs in
                self?.rig.setPWTable(recs.map { (angle: Float($0.angleDeg), p: Float($0.p), w: Float($0.w)) })
            }
                .store(in: &cancellables)
            diagnostics.$heightScale.sink { [weak self] v in self?.rig.setHeightScale(Float(v)) }
                .store(in: &cancellables)
            diagnostics.$showMarkers.sink { [weak self] v in self?.rig.setShowMarkers(v) }
                .store(in: &cancellables)
            diagnostics.$showGrid.sink { [weak self] v in self?.rig.setShowGrid(v) }
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
