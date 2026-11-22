import ARKit
import AVFoundation
import SwiftUI

/// 顔トラッキングで「頭の位置」を取る。座標は画面中心を原点にした画面基準（単位はメートル）。
///   x: 画面の右が +、y: 画面の上が +、z: 画面から利用者へ向かう距離（常に正）
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
    private var _faceActive = false
    private var _lastFaceTime: TimeInterval?   // 最後に顔を捉えた時刻（CACurrentMediaTime）

    var head: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _head }
    var faceActive: Bool { lock.lock(); defer { lock.unlock() }; return _faceActive }

    /// 最後に顔を捉えてからの秒数。まだ一度も捉えていなければ nil。デバッグ表示用。
    var secondsSinceFace: Int? {
        lock.lock(); defer { lock.unlock() }
        guard let t = _lastFaceTime else { return nil }
        return max(0, Int(CACurrentMediaTime() - t))
    }

    private var session: ARSession?

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
        guard ARFaceTrackingConfiguration.isSupported else {
            mode = .unsupported
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            mode = .denied
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted { self?.runSession() } else { self?.mode = .denied }
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
    }

    private func runSession() {
        let session = ARSession()
        session.delegate = self
        self.session = session
        mode = .searching
        session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
    }

    private func setFace(active: Bool) {
        lock.lock(); _faceActive = active; lock.unlock()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            setFace(active: false)
            publish(.searching)
            return
        }
        // 顔の位置をカメラ座標へ直す（カメラは端末と一緒に動くので、相対位置を取る）
        let rel = simd_mul(simd_inverse(frame.camera.transform), face.transform).columns.3
        // カメラ座標は「横向き（ホームボタン右）」基準。画面の向きに合わせて x/y を入れ替える
        var sx: Float = 0, sy: Float = 0
        switch Self.interfaceOrientation() {
        case .landscapeRight:      (sx, sy) = (rel.x, rel.y)
        case .landscapeLeft:       (sx, sy) = (-rel.x, -rel.y)
        case .portraitUpsideDown:  (sx, sy) = (-rel.y, rel.x)
        default:                   (sx, sy) = (rel.y, -rel.x)   // 縦持ち
        }
        // 顔はカメラの前（-z 側）にいるので、距離は -z。極端な値は丸める
        let dist = min(max(abs(rel.z), 0.15), 0.9)
        lock.lock()
        _head = SIMD3<Float>(sx, sy, dist)
        _faceActive = true
        _lastFaceTime = CACurrentMediaTime()
        lock.unlock()
        publish(.tracking)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        setFace(active: false)
        // カメラ許可の取り消しなどで失敗した場合も、落とさずドラッグ操作へ切り替える
        publish(AVCaptureDevice.authorizationStatus(for: .video) == .authorized ? .unsupported : .denied)
    }

    private func publish(_ new: Mode) {
        DispatchQueue.main.async { [weak self] in
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
