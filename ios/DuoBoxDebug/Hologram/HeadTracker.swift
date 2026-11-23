import ARKit
import AVFoundation
import CoreImage
import SwiftUI

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

    /// 軸対応を適用した目の位置（カメラ相対、シーン軸）。シーン側はこれにカメラの位置を足すだけ。
    var mappedHead: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return lockedAxisMap.apply(_head) }

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
    /// 映像を 180° 回して表示するか（顔の上方向から判定して保持する）
    private var calibrationRotated = false
    private var calibrationRotateVotes = 0
    private var calibrationBusy = false
    private var calibrationLastImage: TimeInterval = 0
    private let calibrationQueue = DispatchQueue(label: "hologram.calibration.video", qos: .userInitiated)
    private lazy var calibrationContext = CIContext(options: [.cacheIntermediates: false])

    /// 切り分け表示用：映像を 180° 補正しているか
    var calibrationVideoRotated: Bool { lock.lock(); defer { lock.unlock() }; return calibrationRotated }

    func setCalibrationFeed(_ feed: CalibrationFeed?, viewport: CGSize) {
        lock.lock()
        calibrationFeed = feed
        calibrationViewport = viewport
        if feed == nil { calibrationRotated = false; calibrationRotateVotes = 0 }
        lock.unlock()
    }

    /// 正規化画像（左上原点）→ 表示するビューの pt（左上原点）。回転の補正と鏡写しまで含む
    private static func imageToView(_ display: CGAffineTransform, viewport vp: CGSize,
                                    rotated: Bool, mirror: Bool) -> CGAffineTransform {
        var m = display.concatenating(CGAffineTransform(scaleX: vp.width, y: vp.height))
        if rotated { m = m.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: vp.width, ty: vp.height)) }
        if mirror { m = m.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: vp.width, ty: 0)) }
        return m
    }

    /// ワールド座標の点を、撮影画像の正規化座標（左上原点）へ直す。capturedImage の向きは landscapeRight
    private static func normalizedImagePoint(_ world: SIMD3<Float>, camera: ARCamera, imageSize: CGSize) -> CGPoint? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let p = camera.projectPoint(world, orientation: .landscapeRight, viewportSize: imageSize)
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return CGPoint(x: p.x / imageSize.width, y: p.y / imageSize.height)
    }

    /// 画面座標（x 右、y 上、z は距離）の点を、表示中の映像の上の位置へ直す。映像と同じ変換を通す
    func projectForCalibration(_ s: SIMD3<Float>, flip: Bool) -> CGPoint? {
        lock.lock()
        let storedCamera = calibrationCamera, o = calibrationOrientation, vp = calibrationViewport
        let mirror = calibrationMirror, rotated = calibrationRotated
        let display = calibrationDisplay, imageSize = calibrationImageSize
        lock.unlock()
        guard let camera = storedCamera, vp.width > 0, vp.height > 0, s.z > 0 else { return nil }
        let world = simd_mul(simd_inverse(camera.viewMatrix(for: o)), SIMD4<Float>(s.x, s.y, -s.z, 1))
        guard let n = Self.normalizedImagePoint(SIMD3<Float>(world.x, world.y, world.z), camera: camera, imageSize: imageSize) else { return nil }
        let p = n.applying(Self.imageToView(display, viewport: vp, rotated: rotated, mirror: mirror != flip))
        guard p.x.isFinite, p.y.isFinite else { return nil }
        return p
    }

    /// 顔の上方向が映像の上を向くように、180° 補正の要否を決める。向きが続けて同じときだけ切り替える
    private func updateCalibrationRotation(frame: ARFrame, face: ARFaceAnchor, display: CGAffineTransform, viewport vp: CGSize) {
        let c = face.transform.columns.3, up = face.transform.columns.1
        let base = SIMD3<Float>(c.x, c.y, c.z)
        let top = base + SIMD3<Float>(up.x, up.y, up.z) * 0.08
        let size = frame.camera.imageResolution
        guard let a = Self.normalizedImagePoint(base, camera: frame.camera, imageSize: size),
              let b = Self.normalizedImagePoint(top, camera: frame.camera, imageSize: size) else { return }
        let m = Self.imageToView(display, viewport: vp, rotated: false, mirror: false)
        let pa = a.applying(m), pb = b.applying(m)
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        // 顔が大きく傾いているときは判定しない
        guard abs(dy) > abs(dx) * 1.5 else { return }
        let needsRotation = dy > 0
        lock.lock()
        if needsRotation == calibrationRotated {
            calibrationRotateVotes = 0
        } else {
            calibrationRotateVotes += 1
            if calibrationRotateVotes >= 5 {
                calibrationRotated = needsRotation
                calibrationRotateVotes = 0
            }
        }
        lock.unlock()
    }

    /// 映像を約15fpsで表示用の画像にする。ARFrame は持ち続けない（ARKit のバッファ枯渇を防ぐ）
    private func feedCalibrationVideo(_ frame: ARFrame, face: ARFaceAnchor?) {
        let now = CACurrentMediaTime()
        let o = Self.interfaceOrientation()
        lock.lock()
        let vp = calibrationViewport
        guard let feed = calibrationFeed, vp.width > 0, vp.height > 0 else { lock.unlock(); return }
        lock.unlock()
        let t = frame.displayTransform(for: o, viewportSize: vp)
        if let face, face.isTracked { updateCalibrationRotation(frame: frame, face: face, display: t, viewport: vp) }
        // 行列式が正なら映像は鏡写しになっていないので、自撮りと同じ向きへ左右反転する
        let mirror = t.a * t.d - t.b * t.c > 0
        lock.lock()
        calibrationCamera = frame.camera
        calibrationOrientation = o
        calibrationMirror = mirror
        calibrationDisplay = t
        calibrationImageSize = frame.camera.imageResolution
        let rotated = calibrationRotated
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
                .concatenating(Self.imageToView(t, viewport: vp, rotated: rotated, mirror: mirror))
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
        }
        feedCalibrationVideo(frame, face: faces.first)
        guard let face = faces.first, face.isTracked else {
            setFace(active: false)
            publishCalibrationSample(nil)
            publish(.searching)
            return
        }
        // 目の位置＝左右の目の中点（顔アンカーのローカル座標 → ARKit のワールド座標）
        let leftEye = simd_mul(face.transform, face.leftEyeTransform).columns.3
        let rightEye = simd_mul(face.transform, face.rightEyeTransform).columns.3
        let eyeMid = (leftEye + rightEye) * 0.5
        // カメラ座標へ直す（カメラは端末と一緒に動くので、カメラから見た相対位置を取る）
        let rel = simd_mul(simd_inverse(frame.camera.transform), eyeMid)
        // 画面の向きに合わせた座標（x 右、y 上、−z 前）を ARKit から取る。向きはメインで更新したキャッシュ
        let screen = simd_mul(frame.camera.viewMatrix(for: Self.interfaceOrientation()), eyeMid)
        let rawDist = -screen.z
        let screenRel = SIMD3<Float>(screen.x, screen.y, screen.z)
        lock.lock()
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
        _head = SIMD3<Float>(screen.x, screen.y, min(max(rawDist, 0.15), 0.9))
        _faceActive = true
        _lastFaceTime = CACurrentMediaTime()
        lock.unlock()
        // キャリブレーションには 1€ を通す前・カメラ位置を足す前の生の値を渡す
        let view = frame.camera.viewMatrix(for: Self.interfaceOrientation())
        let leftScreen = simd_mul(view, leftEye), rightScreen = simd_mul(view, rightEye)
        publishCalibrationSample(.init(screen: SIMD3<Float>(screen.x, screen.y, rawDist),
                                       camera: SIMD3<Float>(rel.x, rel.y, rel.z),
                                       leftEye: SIMD3<Float>(leftScreen.x, leftScreen.y, -leftScreen.z),
                                       rightEye: SIMD3<Float>(rightScreen.x, rightScreen.y, -rightScreen.z),
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
        var screen: SIMD3<Float>   // 画面座標（x 右、y 上、z は距離）。1€ の前、カメラ位置を足す前
        var camera: SIMD3<Float>   // ARKit のカメラ座標
        var leftEye: SIMD3<Float>  // 左目（画面座標、z は距離）
        var rightEye: SIMD3<Float> // 右目（画面座標、z は距離）
        var time: TimeInterval
    }
    @Published var image: CGImage?
    @Published var sample: Sample?
}
