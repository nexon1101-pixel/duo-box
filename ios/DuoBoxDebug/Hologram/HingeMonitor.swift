import SwiftUI
import UIKit

/// 折り角度（ヒンジ）と折り目の位置を取る。
///
/// 【重要】iOS 27.1 SDK のヒンジAPI（UIHingeInteraction / UIHinge.angle）は Linux クラウドで
/// ビルド確認できていない。シンボル名・初期化の形は仕様書の記述からの推定なので、
/// CI のビルドで型が合わなければ「★要確認」の2か所だけ直せばよい（他のファイルはこの型の外に依存しない）。
///
/// 取れない環境（iOS 27.1 未満・非折りたたみ端末・シミュレータ）では angle = nil のままで、
/// 呼び出し側は全開 180° として従来どおりの単一平面の動きにする。
final class HingeMonitor: ObservableObject {
    /// 状態ラベル用の角度（度）。取れていなければ nil。メインスレッドで更新。
    @Published private(set) var angleDegrees: Double?

    /// 折り目の位置が変わった（reserved regions が取れた場合）ときにレイアウトし直す合図。
    var onFoldChange: (() -> Void)?

    private let lock = NSLock()
    private var _radians: Double?

    /// 描画スレッドから読む折り角度（ラジアン）。nil なら取得できていない。
    var radians: Double? { lock.lock(); defer { lock.unlock() }; return _radians }

    /// 折り角度の取得を、このビューに仕掛ける。
    func attach(to view: UIView) {
        if #available(iOS 27.1, *) {
            installHingeInteraction(on: view)
        }
        // iOS 27.1 未満：何も仕掛けない（angle は nil のまま＝全開 180° 扱い）
    }

    @available(iOS 27.1, *)
    private func installHingeInteraction(on view: UIView) {
        // UIHingeInteraction のハンドラは (interaction, update) の2引数で、
        // update.hinge（UIHinge?）の angle がラジアン。hinge が nil のときは
        // ヒンジのない画面なので何もしない（全開扱いのまま）。
        // 形は iPhone Duo 向けの公開サンプル（bleepingswift 等）で確認済み（2026-11-22 検品）。
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let hinge = update.hinge else { return }
            self?.update(radians: Double(hinge.angle))
        }
        view.addInteraction(interaction)
    }

    private func update(radians: Double) {
        lock.lock(); _radians = radians; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.angleDegrees = radians * 180 / .pi
            // 折り目の有効／無効はヒンジ変化と一緒に変わるので、レイアウトも見直させる
            self?.onFoldChange?()
        }
    }

    /// 折り目（.division の reserved region）の、ビュー座標での Y 位置。
    ///
    /// UIView.reservedRegions(kind: .division) で有効な折り目の領域が取れる
    /// （公開サンプルで確認済み、2026-11-22 検品）。取れない環境・折り目が
    /// 無効なときは nil で、呼び出し側が「画面中央」で代用する（フォールバック）。
    /// 折り目の帯の厚みは無視し、中心線（midY）を境にする。
    func foldY(in view: UIView) -> CGFloat? {
        if #available(iOS 27.1, *) {
            let folds = view.reservedRegions(kind: .division).filter { $0.isActive }
            // 横方向の帯（幅 ≧ 高さ）を水平な折り目として優先する
            let fold = folds.first { $0.frame.width >= $0.frame.height } ?? folds.first
            return fold?.frame.midY
        }
        return nil
    }

    /// 内側カメラ（.occlusion の reserved region）の、ビュー座標での frame。
    ///
    /// .division と同じ方法で、有効な領域だけを取る。カメラ使用開始で後から有効になることがあるので、
    /// 呼び出し側が定期的に読み直す。複数あるときは画面の横中央に最も近いものを使う。
    /// 取れない環境・有効な領域がないときは nil（呼び出し側は既定値で動く）。
    func occlusionFrame(in view: UIView) -> CGRect? {
        let midX = view.bounds.midX
        return occlusionFrames(in: view).min { abs($0.midX - midX) < abs($1.midX - midX) }
    }

    /// 有効な .occlusion の frame を全部返す（診断用。左右の取り違えの調査に使う）
    func occlusionFrames(in view: UIView) -> [CGRect] {
        if #available(iOS 27.1, *) {
            return view.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map { $0.frame }
                .filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
        }
        return []
    }
}
