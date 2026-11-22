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
    private var _faceActive = false
    private var _lastFaceTime: TimeInterval?   // 最後に顔を捉えた時刻（CACurrentMediaTime）

    var head: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _head }
    /// 切り分け表示用：didUpdate で計算した rel そのもの（符号もクランプもそのまま）
    var rawRel: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _rawRel }
    var faceActive: Bool { lock.lock(); defer { lock.unlock() }; return _faceActive }

    // MARK: - キャリブレーション（軸対応・ホーム位置・視差ゲイン）
    // 生の目位置 raw = (x, y, dist)（メートル、`head` と同じ）から、シーン座標への変換はこのクラスの出力段に一元化する。
    //   シーン側の目の位置 = 基準の目位置 + gain × (map(raw) − map(home))
    // gain はホームからの相対移動にだけ掛かる（絶対位置には掛けない）。

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

    static let gainRange: ClosedRange<Float> = 0.6...1.3
    private enum Key {
        static let axis = "hologram.calib.axis"      // [xAxis, xSign, yAxis, ySign]
        static let home = "hologram.calib.homeRaw"   // [x, y, z]
        static let gain = "hologram.calib.gain"
    }

    /// UI 用（メインスレッドで更新）。描画スレッドは lock 内の lockedAxisMap / lockedHomeRaw / lockedGain を読む。
    @Published private(set) var axisMap = AxisMap.identity
    @Published private(set) var homeRaw: SIMD3<Float>?
    @Published private(set) var gain: Float = 1.0
    /// 軸キャリブレーションの進行
    enum AxisStep: Equatable { case idle, front, left, up, done }
    @Published private(set) var axisStep: AxisStep = .idle
    @Published private(set) var calibMessage = ""

    private var lockedAxisMap = AxisMap.identity
    private var lockedHomeRaw: SIMD3<Float>?
    private var lockedGain: Float = 1.0
    private var recent: [SIMD3<Float>] = []          // 直近の生サンプル（静止位置の平均用）
    private var frontRaw: SIMD3<Float>?
    private var leftAxis = 0

    /// 起動時に保存値を復元する（init から）
    private func loadCalibration() {
        let d = UserDefaults.standard
        if let a = d.array(forKey: Key.axis) as? [Double], a.count == 4 {
            lockedAxisMap = AxisMap(xAxis: min(max(Int(a[0]), 0), 2), xSign: a[1] < 0 ? -1 : 1,
                               yAxis: min(max(Int(a[2]), 0), 2), ySign: a[3] < 0 ? -1 : 1)
        }
        if let h = d.array(forKey: Key.home) as? [Double], h.count == 3 {
            lockedHomeRaw = SIMD3<Float>(Float(h[0]), Float(h[1]), Float(h[2]))
        }
        if d.object(forKey: Key.gain) != nil {
            lockedGain = min(max(Float(d.double(forKey: Key.gain)), Self.gainRange.lowerBound), Self.gainRange.upperBound)
        }
        axisMap = lockedAxisMap; homeRaw = lockedHomeRaw; gain = lockedGain
    }

    override init() {
        super.init()
        loadCalibration()
    }

    private func saveAxisMap() {
        let m = lockedAxisMap
        UserDefaults.standard.set([Double(m.xAxis), Double(m.xSign), Double(m.yAxis), Double(m.ySign)], forKey: Key.axis)
    }

    /// 手動で軸対応を選び直す（自動判定が外れた場合用）
    func setAxisMap(_ m: AxisMap) {
        lock.lock(); lockedAxisMap = m; lock.unlock()
        axisMap = m
        saveAxisMap()
    }

    func setGain(_ g: Float) {
        let v = min(max(g, Self.gainRange.lowerBound), Self.gainRange.upperBound)
        lock.lock(); lockedGain = v; lock.unlock()
        gain = v
        UserDefaults.standard.set(Double(v), forKey: Key.gain)
    }

    /// 直近サンプルの平均（静止位置）。顔が見えていなければ nil
    private func stillPosition() -> SIMD3<Float>? {
        lock.lock(); defer { lock.unlock() }
        guard _faceActive, !recent.isEmpty else { return nil }
        return recent.reduce(SIMD3<Float>(repeating: 0), +) / Float(recent.count)
    }

    /// ホーム位置：今の目位置を記録する
    func recordHome() {
        guard let p = stillPosition() else { calibMessage = "顔が見えていません。カメラの方を向いてください"; return }
        lock.lock(); lockedHomeRaw = p; lock.unlock()
        homeRaw = p
        UserDefaults.standard.set([Double(p.x), Double(p.y), Double(p.z)], forKey: Key.home)
        calibMessage = "ホームを記録しました"
    }

    func startAxisCalibration() {
        frontRaw = nil
        axisStep = .front
        calibMessage = "① 普段どおり正面を見て静止し、「記録」を押す"
    }

    func cancelAxisCalibration() { axisStep = .idle; calibMessage = "" }

    /// 軸キャリブレーションの現在の手順を記録して次へ進める
    func captureAxisStep() {
        guard let p = stillPosition() else { calibMessage = "顔が見えていません。カメラの方を向いてください"; return }
        let minMove: Float = 0.015   // これ未満の動きは判定しない（1.5cm）
        switch axisStep {
        case .front:
            frontRaw = p
            axisStep = .left
            calibMessage = "② 顔を左へ動かして静止し、「記録」を押す"
        case .left:
            guard let f = frontRaw else { startAxisCalibration(); return }
            let d = p - f
            let a = (0..<3).max { abs(d[$0]) < abs(d[$1]) } ?? 0
            guard abs(d[a]) >= minMove else { calibMessage = "動きが小さすぎます。もっと大きく左へ動かして再度「記録」"; return }
            leftAxis = a
            var m = axisMap
            m.xAxis = a
            m.xSign = d[a] > 0 ? -1 : 1      // 左へ動いた＝シーンの −x。生値が増えたなら符号を反転
            setAxisMap(m)
            axisStep = .up
            calibMessage = "③ 顔を上へ動かして静止し、「記録」を押す"
        case .up:
            guard let f = frontRaw else { startAxisCalibration(); return }
            let d = p - f
            // 左で使った軸は除く
            let a = (0..<3).filter { $0 != leftAxis }.max { abs(d[$0]) < abs(d[$1]) } ?? 1
            guard abs(d[a]) >= minMove else { calibMessage = "動きが小さすぎます。もっと大きく上へ動かして再度「記録」"; return }
            var m = axisMap
            m.yAxis = a
            m.ySign = d[a] > 0 ? 1 : -1
            setAxisMap(m)
            axisStep = .done
            calibMessage = "軸対応を決定しました。外れていれば下のセレクタで直せます"
        default:
            break
        }
    }

    func resetCalibration() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Key.axis); d.removeObject(forKey: Key.home); d.removeObject(forKey: Key.gain)
        lock.lock(); lockedAxisMap = .identity; lockedHomeRaw = nil; lockedGain = 1.0; lock.unlock()
        axisMap = .identity; homeRaw = nil; gain = 1.0
        frontRaw = nil; axisStep = .idle; calibMessage = "キャリブレーションを既定に戻しました"
    }

    /// シーン側へ渡す、基準位置からの目の移動量（シーン座標、メートル）。
    /// = gain × (map(raw) − map(home))。ホーム未記録なら defaultHomeMapped（変換後座標での既定の基準）を使う。
    func sceneDelta(defaultHomeMapped: SIMD3<Float>) -> SIMD3<Float> {
        lock.lock(); defer { lock.unlock() }
        let cur = lockedAxisMap.apply(_head)
        let home = lockedHomeRaw.map { lockedAxisMap.apply($0) } ?? defaultHomeMapped
        return (cur - home) * lockedGain
    }

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
        let dist = min(max(abs(rel.z), 0.15), 0.9)
        lock.lock()
        _rawRel = SIMD3<Float>(rel.x, rel.y, rel.z)
        _head = SIMD3<Float>(sx, sy, dist)
        recent.append(_head)
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
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
