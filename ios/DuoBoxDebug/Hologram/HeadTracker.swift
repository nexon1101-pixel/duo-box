import ARKit
import AVFoundation
import SwiftUI

/// 顔トラッキングで「目の位置」を取る。座標は **フロントカメラのレンズを原点にした、上パネル基準**（単位はメートル）。
///   x: 画面の右が +、y: 画面の上が +、z: 画面から利用者へ向かう距離（常に正）
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
    private var _rawRel = SIMD3<Float>(0, 0, 0)   // 変換前の本当の生値（ARKitカメラ座標。向き変換・abs・クランプを通す前）
    private var _rawDistance: Float = 0        // クランプ前の距離 abs(rel.z)
    private var _faceActive = false
    private var _lastFaceTime: TimeInterval?   // 最後に顔を捉えた時刻（CACurrentMediaTime）

    var head: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _head }
    /// 切り分け表示用：クランプ前の距離 abs(rel.z)（m）。クランプ後は head.z
    var rawDistance: Float { lock.lock(); defer { lock.unlock() }; return _rawDistance }
    /// 切り分け表示用：didUpdate で計算した rel そのもの（符号もクランプもそのまま）
    var rawRel: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _rawRel }
    var faceActive: Bool { lock.lock(); defer { lock.unlock() }; return _faceActive }

    // MARK: - 軸対応（固定値）
    // 目の位置は絶対位置だけを使う：シーン側の目の位置 = カメラの位置（機種プロファイル）+ map(head)。
    // ホーム（基準位置の記録）と視差ゲインは廃止した（手順4）。残る変換は軸対応だけ。
    // 軸対応は「その場で測る手順」ではなく固定値として持ち、実機でマーカーを見て外れていれば
    // パネルのセレクタで直す（値は保存される）。

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
    }

    private enum Key {
        static let axis = "hologram.calib.axis"      // [xAxis, xSign, yAxis, ySign]
    }

    /// UI 用（メインスレッドで更新）。描画スレッドは lock 内の lockedAxisMap を読む。
    @Published private(set) var axisMap = AxisMap.identity

    private var lockedAxisMap = AxisMap.identity

    /// 起動時に保存値を復元する（init から）。旧バージョンのホーム／ゲインの保存値は掃除する
    private func loadCalibration() {
        let d = UserDefaults.standard
        if let a = d.array(forKey: Key.axis) as? [Double], a.count == 4 {
            lockedAxisMap = AxisMap(xAxis: min(max(Int(a[0]), 0), 2), xSign: a[1] < 0 ? -1 : 1,
                               yAxis: min(max(Int(a[2]), 0), 2), ySign: a[3] < 0 ? -1 : 1)
        }
        d.removeObject(forKey: "hologram.calib.homeRaw")
        d.removeObject(forKey: "hologram.calib.gain")
        axisMap = lockedAxisMap
    }

    override init() {
        super.init()
        loadCalibration()
    }

    private func saveAxisMap() {
        let m = lockedAxisMap
        UserDefaults.standard.set([Double(m.xAxis), Double(m.xSign), Double(m.yAxis), Double(m.ySign)], forKey: Key.axis)
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
        guard let face = faces.first, face.isTracked else {
            setFace(active: false)
            publish(.searching)
            return
        }
        // 目の位置＝左右の目の中点（顔アンカーのローカル座標 → ARKit のワールド座標）
        let leftEye = simd_mul(face.transform, face.leftEyeTransform).columns.3
        let rightEye = simd_mul(face.transform, face.rightEyeTransform).columns.3
        let eyeMid = (leftEye + rightEye) * 0.5
        // カメラ座標へ直す（カメラは端末と一緒に動くので、カメラから見た相対位置を取る）
        let rel = simd_mul(simd_inverse(frame.camera.transform), eyeMid)
        // カメラ座標は「横向き（ホームボタン右）」基準。画面の向きに合わせて x/y を入れ替える
        var sx: Float = 0, sy: Float = 0
        switch Self.interfaceOrientation() {
        case .landscapeRight:      (sx, sy) = (rel.x, rel.y)
        case .landscapeLeft:       (sx, sy) = (-rel.x, -rel.y)
        case .portraitUpsideDown:  (sx, sy) = (-rel.y, rel.x)
        default:                   (sx, sy) = (rel.y, -rel.x)   // 縦持ち
        }
        // 目はカメラの前（-z 側）にいるので、距離は -z。極端な値は丸める
        let rawDist = abs(rel.z)
        let dist = min(max(rawDist, 0.15), 0.9)
        lock.lock()
        _rawRel = SIMD3<Float>(rel.x, rel.y, rel.z)
        _rawDistance = rawDist
        _head = SIMD3<Float>(sx, sy, dist)
        _faceActive = true
        _lastFaceTime = CACurrentMediaTime()
        lock.unlock()
        publish(.tracking)
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
        cachedOrientation = scene?.interfaceOrientation ?? .portrait
        return cachedOrientation
    }
}
