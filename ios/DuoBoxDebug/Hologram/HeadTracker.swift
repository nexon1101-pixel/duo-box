import ARKit
import AVFoundation
import CoreImage
import SwiftUI
import simd

/// 顔トラッキングで「目の位置」を取る。座標は **フロントカメラのレンズを原点にした、画面の向き基準**（単位はメートル）。
/// ARKit の viewMatrix(for: 画面の向き) で変換する（x: 画面の右、y: 画面の上、−z: 画面の前）。
/// head の z は距離（−z）で、正の値だけを 0.15〜0.9m に丸めて使う。
/// 目の位置は左右の目（leftEyeTransform / rightEyeTransform）の中点。
/// 上パネル座標（折り目が原点）へ直すときは、呼び出し側がカメラの位置（機種プロファイル）を足す。
final class HeadTracker: NSObject, ObservableObject, ARSessionDelegate {
    enum Mode: Equatable {
        case starting
        case tracking        // 顔を捉えている
        case searching       // 顔トラッキング中だが顔が見えていない
        case denied          // カメラ許可なし
        case unsupported     // 機種・環境が非対応（シミュレータなど）
    }

    /// 状態ラベル用（メインスレッドで更新）
    @Published private(set) var mode: Mode = .starting

    /// 描画スレッドから読むための最新の頭位置。lock で保護する。
    private let lock = NSLock()
    private var _head = SIMD3<Float>(0, 0, 0.30)
    private var _rawRel = SIMD3<Float>(0, 0, 0)   // 変換前の生値（ARKit のカメラ座標）
    private var _screenRel = SIMD3<Float>(0, 0, 0) // 変換後の生値（画面座標。丸める前）
    private var _rawDistance: Float = 0        // 丸める前の距離 −z（符号つき）
    private var _wrongSignCount = 0            // 距離が 0 以下で捨てた回数
    private var _faceActive = false
    private var _lastFaceTime: TimeInterval?   // 最後に顔を捉えた時刻（CACurrentMediaTime）
    private var _frameTime: TimeInterval = 0   // いまの目の位置を測った ARFrame の時刻

    var head: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _head }
    /// 切り分け表示用：丸める前の距離 −z（m、符号つき）。丸めた後は head.z
    var rawDistance: Float { lock.lock(); defer { lock.unlock() }; return _rawDistance }
    /// 切り分け表示用：変換前（ARKit のカメラ座標）
    var rawRel: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _rawRel }
    /// 切り分け表示用：変換後（画面座標：x 右、y 上、−z 前）
    var screenRel: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _screenRel }
    /// 距離の符号が逆（目が画面の後ろ）で捨てた回数
    var wrongSignCount: Int { lock.lock(); defer { lock.unlock() }; return _wrongSignCount }
    var faceActive: Bool { lock.lock(); defer { lock.unlock() }; return _faceActive }

    // MARK: - 軸対応（固定値）
    // 目の位置は絶対位置だけを使う：シーン側の目の位置 = カメラの位置（機種プロファイル）+ map(head)。
    // ホーム（基準位置の記録）と視差ゲインは廃止した（手順4）。残る変換は軸対応だけ。
    // 軸対応は機種IDごとに保存する。保存値がなければ「そのまま」を使う。
    // 旧キー hologram.calib.axis は手書きの入れ替え後の座標に対する値なので、読まない。

    /// 生座標→シーン座標の軸対応。sceneX = xSign × raw[xAxis]、sceneY = ySign × raw[yAxis]（軸 0=x, 1=y, 2=z）。z は常に raw の距離。
    struct AxisMap: Equatable {
        var xAxis = 0, xSign: Float = 1
        var yAxis = 1, ySign: Float = 1
        static let identity = AxisMap()
        /// ピッカー用の番号（0..5 = +x, −x, +y, −y, +z, −z）
        static func code(axis: Int, sign: Float) -> Int { axis * 2 + (sign < 0 ? 1 : 0) }
        static func decode(_ c: Int) -> (axis: Int, sign: Float) { (min(max(c / 2, 0), 2), c % 2 == 0 ? 1 : -1) }
        static let labels = ["+x", "−x", "+y", "−y", "+z", "−z"]
        func apply(_ r: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(xSign * r[xAxis], ySign * r[yAxis], r.z)
        }
        /// apply の逆。x・y が別々の横軸を使っていないと戻せないので nil
        func inverse(_ m: SIMD3<Float>) -> SIMD3<Float>? {
            guard xAxis != yAxis, xAxis < 2, yAxis < 2 else { return nil }
            var r = SIMD3<Float>(0, 0, m.z)
            r[xAxis] = xSign * m.x
            r[yAxis] = ySign * m.y
            return r
        }
    }

    private let machineID = HologramDeviceProfile.readMachineID()

    /// UI 用（メインスレッドで更新）。描画スレッドは lock 内の lockedAxisMap を読む。
    @Published private(set) var axisMap = AxisMap.identity

    private var lockedAxisMap = AxisMap.identity

    /// 起動時に保存値を復元する（init から）。旧バージョンのホーム／ゲインの保存値は掃除する
    private func loadCalibration() {
        let d = UserDefaults.standard
        lockedAxisMap = HologramCalibrationStore.axisMap(machineID: machineID) ?? .identity
        lockedVideoTurns = HologramCalibrationStore.videoTurns(machineID: machineID)
        videoTurns = lockedVideoTurns
        d.removeObject(forKey: "hologram.calib.homeRaw")
        d.removeObject(forKey: "hologram.calib.gain")
        axisMap = lockedAxisMap
    }

    override init() {
        super.init()
        loadCalibration()
    }

    private func saveAxisMap() {
        lock.lock(); let m = lockedAxisMap; lock.unlock()
        HologramCalibrationStore.saveAxisMap(m, machineID: machineID)
    }

    /// 軸対応の固定値を選び直す（マーカーで見て外れていた場合用）
    func setAxisMap(_ m: AxisMap) {
        lock.lock(); lockedAxisMap = m; lock.unlock()
        axisMap = m
        saveAxisMap()
    }

    // MARK: - 映像の向き（キャリブレーションの最初に選ぶ。機種IDごとに保存）

    /// 選んだ向き：自撮りの映像を時計回りに 90° × この数だけ回すと、顔がまっすぐになる（0〜3）
    @Published private(set) var videoTurns = 0
    /// 片目を閉じたときに、開いている方の目を使うか（既定はオン）
    static let closedBlink: Float = 0.6   // これより大きければ閉じている
    static let openBlink: Float = 0.35    // これより小さければ開いている
    private var _useOpenEye = true
    /// 片目の切り替え：同じ状態がこの秒数続いたら切り替え、この秒数かけて目の位置を移す
    static let eyeSwitchHold: TimeInterval = 0.25
    static let eyeSwitchBlend: Float = 0.3
    // ARSession の delegate のキューでだけ触る
    private var eyeWantCandidate: Float = 0.5
    private var eyeWantSince: TimeInterval = 0
    private var eyeWantStable: Float = 0.5
    private var eyeWeightL: Float = 0.5
    private var eyeWeightTime: TimeInterval?
    var useOpenEye: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _useOpenEye }
        set { lock.lock(); _useOpenEye = newValue; lock.unlock() }
    }
    private var lockedVideoTurns = 0

    /// 向きを選び直す。変わったときは true を返し、前の向きで測った軸対応を「そのまま」へ戻す
    @discardableResult
    func setVideoTurns(_ turns: Int) -> Bool {
        let t = ((turns % 4) + 4) % 4
        lock.lock()
        let changed = t != lockedVideoTurns
        lockedVideoTurns = t
        if changed { lockedAxisMap = .identity }
        lock.unlock()
        videoTurns = t
        HologramCalibrationStore.saveVideoTurns(t, machineID: machineID)
        if changed {
            axisMap = .identity
            saveAxisMap()
            HologramCalibrationStore.clearMeasured(machineID: machineID)
        }
        return changed
    }

    /// 画面座標の x・y を、選んだ向きの分だけ回す。
    /// 表示は「鏡写しのあとに時計回り」なので、鏡写しを足した映像では座標は反時計回り、元から鏡写しの映像では時計回りになる
    static func turnCoordinates(_ v: SIMD3<Float>, turns: Int, mirrored: Bool) -> SIMD3<Float> {
        let counterClockwise = mirrored ? turns : (4 - turns) % 4
        switch counterClockwise {
        case 1: return SIMD3<Float>(-v.y, v.x, v.z)
        case 2: return SIMD3<Float>(-v.x, -v.y, v.z)
        case 3: return SIMD3<Float>(v.y, -v.x, v.z)
        default: return v
        }
    }

    /// 行列式が正なら映像は鏡写しになっていないので、自撮りと同じ向きへ左右反転する
    private static func needsMirror(_ t: CGAffineTransform) -> Bool { t.a * t.d - t.b * t.c > 0 }

    /// 軸対応を適用した目の位置（カメラ相対、シーン軸）。シーン側はこれにカメラの位置を足すだけ。
    var mappedHead: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return lockedAxisMap.apply(_head) }

    /// 描画用：軸対応を適用した目の位置と、それを測った ARFrame の時刻を同時に読む（遅れの計測に使う）
    var eyeSample: (position: SIMD3<Float>, frameTime: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (lockedAxisMap.apply(_head), _frameTime)
    }

    /// 最後に顔を捉えてからの秒数。まだ一度も捉えていなければ nil。デバッグ表示用。
    var secondsSinceFace: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let t = _lastFaceTime else { return nil }
        return max(0, Int(CACurrentMediaTime() - t))
    }

    private var session: ARSession?

    // MARK: - キャリブレーション用の映像と点（ARKit の frame を使い、別のカメラは開かない）

    private weak var calibrationFeed: CalibrationFeed?
    private var calibrationViewport = CGSize.zero
    private var calibrationCamera: ARCamera?
    private var calibrationOrientation = UIInterfaceOrientation.portrait
    private var calibrationMirror = false
    private var calibrationImageSize = CGSize.zero
    private var calibrationDisplay = CGAffineTransform.identity
    /// いま表示している映像の回転（時計回りの 90° の数）
    private var calibrationShownTurns = 0
    /// 向きを選ぶ段は、回していない映像を受け取ってビュー側で4通りに回す
    private var calibrationUnrotated = false
    private var calibrationBusy = false
    private var calibrationLastImage: TimeInterval = 0
    private let calibrationQueue = DispatchQueue(label: "hologram.calibration.video", qos: .userInitiated)
    private lazy var calibrationContext = CIContext(options: [.cacheIntermediates: false])

    func setCalibrationFeed(_ feed: CalibrationFeed?, viewport: CGSize, unrotated: Bool = false) {
        lock.lock()
        calibrationFeed = feed
        calibrationViewport = viewport
        calibrationUnrotated = unrotated
        lock.unlock()
    }

    /// 回す前の映像の大きさ。90°・270° では縦横が入れ替わる（映像が伸びないように）
    private static func baseSize(_ vp: CGSize, turns: Int) -> CGSize {
        turns % 2 == 1 ? CGSize(width: vp.height, height: vp.width) : vp
    }

    /// 正規化画像（左上原点）→ 表示するビューの pt（左上原点）。
    /// 順番は 向きの基準の反転（mirror）→ 選んだ向きの回転（時計回り）→ 表示の鏡映し（flip）。
    /// flip は回転のあとに掛けるので、あごの上下と保存済みの向き（videoTurns）は変わらない
    private static func imageToView(_ display: CGAffineTransform, viewport vp: CGSize,
                                    turns: Int, mirror: Bool, flip: Bool = false) -> CGAffineTransform {
        let base = baseSize(vp, turns: turns)
        var m = display.concatenating(CGAffineTransform(scaleX: base.width, y: base.height))
        if mirror { m = m.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: base.width, ty: 0)) }
        switch turns {
        case 1: m = m.concatenating(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: vp.width, ty: 0))
        case 2: m = m.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: vp.width, ty: vp.height))
        case 3: m = m.concatenating(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: vp.height))
        default: break
        }
        if flip { m = m.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: vp.width, ty: 0)) }
        return m
    }

    /// ワールド座標の点を、撮影画像の正規化座標（左上原点）へ直す。capturedImage の向きは landscapeRight
    private static func normalizedImagePoint(_ world: SIMD3<Float>, camera: ARCamera, imageSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let p = camera.projectPoint(world, orientation: .landscapeRight, viewportSize: imageSize)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
    }

    /// 画面座標（x 右、y 上、z は距離）の点を、鏡映しで表示中の映像の上の位置へ直す。映像と同じ変換を通す。
    /// extraFlip は開発用：鏡映しの上から、点だけをさらに左右反転する
    func projectForCalibration(_ s: SIMD3<Float>, extraFlip: Bool = false) -> CGPoint? {
        lock.lock()
        let storedCamera = calibrationCamera, o = calibrationOrientation, vp = calibrationViewport
        let mirror = calibrationMirror, shownTurns = calibrationShownTurns, turns = lockedVideoTurns
        let display = calibrationDisplay, imageSize = calibrationImageSize
        lock.unlock()
        guard let camera = storedCamera, vp.width > 0, vp.height > 0, s.z > 0 else { return nil }
        // s は向きを回したあとの座標なので、ARKit の画面座標へ戻してから映像へ投影する
        let g1 = Self.turnCoordinates(s, turns: (4 - turns) % 4, mirrored: mirror)
        let world = simd_mul(simd_inverse(camera.viewMatrix(for: o)), SIMD4<Float>(g1.x, g1.y, -g1.z, 1))
        guard let n = Self.normalizedImagePoint(SIMD3<Float>(world.x, world.y, world.z), camera: camera, imageSize: imageSize) else { return nil }
        let p = n.applying(Self.imageToView(display, viewport: vp, turns: shownTurns, mirror: mirror, flip: !extraFlip))
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }

    /// 映像を約15fpsで表示用の画像にする。ARFrame は持ち続けない（ARKit のバッファ枯渇を防ぐ）
    private func feedCalibrationVideo(_ frame: ARFrame) {
        let now = CACurrentMediaTime()
        let o = Self.interfaceOrientation()
        lock.lock()
        let vp = calibrationViewport
        guard let feed = calibrationFeed, vp.width > 0, vp.height > 0 else { lock.unlock(); return }
        let unrotated = calibrationUnrotated
        let turns = unrotated ? 0 : lockedVideoTurns
        lock.unlock()
        let t = frame.displayTransform(for: o, viewportSize: Self.baseSize(vp, turns: turns))
        let mirror = Self.needsMirror(t)
        lock.lock()
        calibrationShownTurns = turns
        calibrationCamera = frame.camera
        calibrationOrientation = o
        calibrationMirror = mirror
        calibrationDisplay = t
        calibrationImageSize = frame.camera.imageResolution
        guard !calibrationBusy, now - calibrationLastImage >= 1.0 / 15 else { lock.unlock(); return }
        calibrationBusy = true
        calibrationLastImage = now
        lock.unlock()
        let buffer = frame.capturedImage
        calibrationQueue.async { [weak self] in
            guard let self else { return }
            let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
            // CI の画素（左下原点）→ 正規化画像（左上原点）→ ビューの pt（左上原点）→ CI の出力（左下原点）
            let toNormalized = CGAffineTransform(a: 1 / w, b: 0, c: 0, d: -1 / h, tx: 0, ty: 1)
            let toOutput = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: vp.height)
            let m = toNormalized
                // 向きを選ぶ段は、ビュー側で回したあとに鏡映しにする
                .concatenating(Self.imageToView(t, viewport: vp, turns: turns, mirror: mirror, flip: !unrotated))
                .concatenating(toOutput)
            let rect = CGRect(origin: .zero, size: vp)
            let image = CIImage(cvPixelBuffer: buffer).transformed(by: m).cropped(to: rect)
            let cg = self.calibrationContext.createCGImage(image, from: rect)
            self.lock.lock(); self.calibrationBusy = false; self.lock.unlock()
            DispatchQueue.main.async { [weak feed] in feed?.image = cg }
        }
    }

    /// 診断用：ARKit の状態（デバッグパネルが読む）。lock で保護。
    struct Diagnostics {
        var isSupported = false
        var authorization = "未確認"
        var sessionState = "未開始"
        var frames = 0                    // 受け取った ARFrame の数
        var lastFrameTime: TimeInterval?  // 最後のフレームの時刻（CACurrentMediaTime）
        var lastAnchorCount = 0           // 直近フレームのアンカー総数
        var lastFaceAnchorCount = 0       // 直近フレームの ARFaceAnchor の数
        var lastFaceTracked: Bool?        // 直近の顔アンカーの isTracked
        var cameraState = "—"             // frame.camera.trackingState
        var lastError: String?
        var interrupted = false
        var videoFormats = 0              // ARFaceTrackingConfiguration.supportedVideoFormats の数
        var usedEye = "—"                 // 目の位置に使っている目（両目の中点／開いている方の目）
        /// カメラの内部パラメータ（画素）と映像の解像度。画角が実際と合っているかの確認用
        var intrinsics: simd_float3x3?
        var imageResolution: CGSize = .zero
        /// 横（映像の幅の方向）と縦（高さの方向）の画角（度）
        var fieldOfViewDeg: (width: Double, height: Double)? {
            guard let k = intrinsics, imageResolution.width > 0, k[0][0] > 0, k[1][1] > 0 else { return nil }
            let fx = Double(k[0][0]), fy = Double(k[1][1])
            return (2 * atan(Double(imageResolution.width) / 2 / fx) * 180 / .pi,
                    2 * atan(Double(imageResolution.height) / 2 / fy) * 180 / .pi)
        }
    }
    private var _diag = Diagnostics()
    func diagnosticsSnapshot() -> Diagnostics { lock.lock(); defer { lock.unlock() }; return _diag }
    private func updateDiag(_ f: (inout Diagnostics) -> Void) { lock.lock(); f(&_diag); lock.unlock() }

    private static func authorizationText() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "許可済み"
        case .denied: return "拒否"
        case .restricted: return "制限あり"
        case .notDetermined: return "未決定"
        @unknown default: return "不明"
        }
    }

    var statusText: String {
        switch mode {
        case .starting: return "顔トラッキングを準備中…"
        case .tracking: return "顔トラッキング動作中"
        case .searching: return "顔が見つかりません（カメラの方を向いてください）"
        case .denied: return "カメラの許可がありません。ドラッグで視点移動（設定アプリで許可すると顔トラッキングが使えます）"
        case .unsupported: return "ドラッグで視点移動（顔トラッキング不可）"
        }
    }

    func start() {
        // 二重起動の防止：onAppear が2回呼ばれても ARSession を2本走らせない（カメラの取り合いで顔が来なくなる）
        guard session == nil else { return }
        let supported = ARFaceTrackingConfiguration.isSupported
        updateDiag {
            $0.isSupported = supported
            $0.authorization = Self.authorizationText()
            $0.videoFormats = supported ? ARFaceTrackingConfiguration.supportedVideoFormats.count : 0
        }
        _ = Self.interfaceOrientation()   // メインスレッドで向きのキャッシュを初期化
        guard supported else {
            updateDiag { $0.sessionState = "非対応（isSupported = false）" }
            mode = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            updateDiag { $0.sessionState = "カメラ権限なし" }
            mode = .denied
        case .notDetermined:
            updateDiag { $0.sessionState = "権限の確認待ち" }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.updateDiag { $0.authorization = Self.authorizationText() }
                    if granted { self?.runSession() } else {
                        self?.updateDiag { $0.sessionState = "カメラ権限なし" }
                        self?.mode = .denied
                    }
                }
            }
        default:
            runSession()
        }
    }

    func stop() {
        session?.pause()
        session = nil
        setFace(active: false)
        updateDiag { $0.sessionState = "停止"; $0.interrupted = false }
    }

    private func runSession() {
        let session = ARSession()
        session.delegate = self
        self.session = session
        mode = .searching
        updateDiag { $0.sessionState = "実行中（フレーム待ち）"; $0.frames = 0; $0.lastFrameTime = nil; $0.lastError = nil }
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    private func setFace(active: Bool) {
        lock.lock(); _faceActive = active; lock.unlock()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }
        let camState: String
        switch frame.camera.trackingState {
        case .normal: camState = "normal"
        case .notAvailable: camState = "notAvailable"
        case .limited(let r): camState = "limited(\(r))"
        }
        updateDiag {
            $0.frames += 1
            $0.lastFrameTime = CACurrentMediaTime()
            $0.sessionState = "実行中"
            $0.lastAnchorCount = frame.anchors.count
            $0.lastFaceAnchorCount = faces.count
            $0.lastFaceTracked = faces.first?.isTracked
            $0.cameraState = camState
            $0.intrinsics = frame.camera.intrinsics
            $0.imageResolution = frame.camera.imageResolution
        }
        feedCalibrationVideo(frame)
        guard let face = faces.first, face.isTracked else {
            setFace(active: false)
            publishCalibrationSample(nil)
            publish(.searching)
            return
        }
        // 目の位置＝左右の目の中点（顔アンカーのローカル座標 → ARKit のワールド座標）。
        // 片目を閉じて見ているときは、開いている方の目を使う（中点のままだと約 3cm 横にずれる）
        let leftEye = simd_mul(face.transform, face.leftEyeTransform).columns.3
        let rightEye = simd_mul(face.transform, face.rightEyeTransform).columns.3
        let blinkL = face.blendShapes[.eyeBlinkLeft]?.floatValue ?? 0
        let blinkR = face.blendShapes[.eyeBlinkRight]?.floatValue ?? 0
        // 目を細めたときに中点と片目を行き来しないよう、同じ状態が 0.25 秒続いてから切り替え、
        // 切り替えのあとも 0.3 秒かけて目の位置を移す（約 3cm の跳びをなくす）
        var want: Float = 0.5                       // 左目の重み。0.5＝中点、1＝左目だけ、0＝右目だけ
        if useOpenEye && blinkL > Self.closedBlink && blinkR < Self.openBlink { want = 0 }
        else if useOpenEye && blinkR > Self.closedBlink && blinkL < Self.openBlink { want = 1 }
        let now = frame.timestamp
        if want != eyeWantCandidate { eyeWantCandidate = want; eyeWantSince = now }
        if now - eyeWantSince >= Self.eyeSwitchHold { eyeWantStable = want }
        let stepDT = Float(min(max(now - (eyeWeightTime ?? now), 0), 0.1))
        eyeWeightTime = now
        let maxStep = stepDT / Self.eyeSwitchBlend * 0.5
        eyeWeightL += min(max(eyeWantStable - eyeWeightL, -maxStep), maxStep)
        let eyeMid = leftEye * eyeWeightL + rightEye * (1 - eyeWeightL)
        let usedEye: String
        if eyeWeightL > 0.95 { usedEye = "左目（右目を閉じている）" }
        else if eyeWeightL < 0.05 { usedEye = "右目（左目を閉じている）" }
        else if abs(eyeWeightL - 0.5) < 0.05 { usedEye = "両目の中点" }
        else { usedEye = "切り替え中" }
        updateDiag { $0.usedEye = usedEye }
        // カメラ座標へ直す（カメラは端末と一緒に動くので、カメラから見た相対位置を取る）
        let rel = simd_mul(simd_inverse(frame.camera.transform), eyeMid)
        // 画面の向きに合わせた座標（x 右、y 上、−z 前）を ARKit から取る。向きはメインで更新したキャッシュ
        let screen = simd_mul(frame.camera.viewMatrix(for: Self.interfaceOrientation()), eyeMid)
        let rawDist = -screen.z
        let screenRel = SIMD3<Float>(screen.x, screen.y, screen.z)
        // G1 の変換のあとに、選んだ向きの分だけ x・y を回す
        let mirrored = Self.needsMirror(frame.displayTransform(for: Self.interfaceOrientation(),
                                                               viewportSize: CGSize(width: 1, height: 1)))
        lock.lock()
        let turns = lockedVideoTurns
        let turned = Self.turnCoordinates(SIMD3<Float>(screen.x, screen.y, rawDist), turns: turns, mirrored: mirrored)
        _rawRel = SIMD3<Float>(rel.x, rel.y, rel.z)
        _screenRel = screenRel
        _rawDistance = rawDist
        // 目が画面の前にないとき（0 以下）と有限でないときは、その回の値を捨てて前の位置を保つ
        guard rawDist > 0, screen.x.isFinite, screen.y.isFinite, rawDist.isFinite else {
            if rawDist <= 0 { _wrongSignCount += 1 }
            _faceActive = false
            lock.unlock()
            publishCalibrationSample(nil)
            return
        }
        _head = SIMD3<Float>(turned.x, turned.y, min(max(rawDist, 0.15), 0.9))
        _frameTime = frame.timestamp
        _faceActive = true
        _lastFaceTime = CACurrentMediaTime()
        lock.unlock()
        // キャリブレーションには 1€ を通す前・カメラ位置を足す前の生の値を渡す
        let view = frame.camera.viewMatrix(for: Self.interfaceOrientation())
        let leftScreen = simd_mul(view, leftEye), rightScreen = simd_mul(view, rightEye)
        publishCalibrationSample(.init(screen: turned,
                                       camera: SIMD3<Float>(rel.x, rel.y, rel.z),
                                       leftEye: Self.turnCoordinates(SIMD3<Float>(leftScreen.x, leftScreen.y, -leftScreen.z),
                                                                     turns: turns, mirrored: mirrored),
                                       rightEye: Self.turnCoordinates(SIMD3<Float>(rightScreen.x, rightScreen.y, -rightScreen.z),
                                                                      turns: turns, mirrored: mirrored),
                                       time: CACurrentMediaTime()))
        publish(.tracking)
    }

    private func publishCalibrationSample(_ sample: CalibrationFeed.Sample?) {
        lock.lock(); let current = calibrationFeed; lock.unlock()
        guard let feed = current else { return }
        DispatchQueue.main.async { [weak feed] in feed?.sample = sample }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        setFace(active: false)
        updateDiag { $0.lastError = error.localizedDescription; $0.sessionState = "失敗" }
        // カメラ許可の取り消しなどで失敗した場合も、落とさずドラッグ操作へ切り替える
        publish(AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? .unsupported : .denied)
    }

    func sessionWasInterrupted(_ session: ARSession) {
        setFace(active: false)
        updateDiag { $0.interrupted = true; $0.sessionState = "中断中" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        updateDiag { $0.interrupted = false; $0.sessionState = "実行中（再開）" }
    }

    private func publish(_ new: Mode) {
        DispatchQueue.main.async { [weak self] in
            _ = Self.interfaceOrientation()   // 向きのキャッシュを更新（描画側の読み取りはメイン以外）
            if self?.mode != new { self?.mode = new }
        }
    }

    /// 画面の向き。デリゲートは毎フレーム呼ばれるので、メインスレッド以外からは
    /// main.sync で取りに行かず、前回メインで読んだ値を返す（詰まり・デッドロック回避）。
    private static var cachedOrientation: UIInterfaceOrientation = .portrait
    private static func interfaceOrientation() -> UIInterfaceOrientation {
        guard Thread.isMainThread else { return cachedOrientation }
        let scene = UIApplication.shared.connectedScenes.first { $0 is UIWindowScene } as? UIWindowScene
        let current = scene?.interfaceOrientation ?? .portrait
        cachedOrientation = current == .unknown ? .portrait : current
        return cachedOrientation
    }
}

/// キャリブレーション画面へ渡す映像と目の位置（メインスレッドで更新）
final class CalibrationFeed: ObservableObject {
    struct Sample: Equatable {
        var screen: SIMD3<Float>   // 画面座標（x 右、y 上、z は距離）。選んだ向きを回したあと。1€ の前、カメラ位置を足す前
        var camera: SIMD3<Float>   // ARKit のカメラ座標
        var leftEye: SIMD3<Float>  // 左目（screen と同じ座標）
        var rightEye: SIMD3<Float> // 右目（screen と同じ座標）
        var time: TimeInterval
    }
    @Published var image: CGImage?
    @Published var sample: Sample?
}
