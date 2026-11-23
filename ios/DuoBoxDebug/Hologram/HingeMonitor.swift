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

    /// occlusion の1領域の、変換前と変換後の frame。
    struct OcclusionReading: Equatable {
        var raw: CGRect          // reservedRegions が返した値
        var converted: CGRect    // ビュー座標へ直した値
        var method: String       // どの根拠で直したか（パネル②に出す）
    }

    /// 有効な .occlusion を、変換前後の組で返す。
    /// カメラ使用開始で後から有効になることがあるので、呼び出し側が定期的に読み直す。
    func occlusionReadings(in view: UIView) -> [OcclusionReading] {
        if #available(iOS 27.1, *) {
            let divisions = view.reservedRegions(kind: .division).filter { $0.isActive }.map { $0.frame }
            return view.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map { $0.frame }
                .filter { !$0.isNull && !$0.isInfinite && !$0.isEmpty }
                .map { Self.reading(raw: $0, divisions: divisions, in: view) }
        }
        return []
    }

    /// 複数あるときは、変換後の中心が画面の横中央に最も近いものを使う
    static func primary(_ readings: [OcclusionReading], in view: UIView) -> OcclusionReading? {
        let midX = view.bounds.midX
        return readings.min { abs($0.converted.midX - midX) < abs($1.converted.midX - midX) }
    }

    /// frame の座標系は公式文書で確認できていないため、実機で確かめられる根拠の順に判定する。
    /// 1. 画面の固定座標系とビューの縦横が入れ替わっていれば、UIKit の変換に任せる
    /// 2. 折り目の帯が、横に走るはずなのに縦長で返っていれば、frame が 90° 回っているとみなす
    /// 3. どちらでもなければ変換しない（「変換なし」と表示する）
    private static func reading(raw: CGRect, divisions: [CGRect], in view: UIView) -> OcclusionReading {
        let b = view.bounds
        if let screen = view.window?.windowScene?.screen {
            let fixed = screen.fixedCoordinateSpace
            let isSwapped = (fixed.bounds.width > fixed.bounds.height) != (b.width > b.height)
            if isSwapped {
                return .init(raw: raw, converted: view.convert(raw, from: fixed), method: "固定座標系から変換")
            }
        }
        if let fold = divisions.first, fold.height > fold.width {
            // 実機の報告（上端から 41pt → 実際は左端から 41pt）に合う向きの 90° 回転
            let turned = CGRect(x: raw.minY, y: b.height - raw.maxX, width: raw.height, height: raw.width)
            return .init(raw: raw, converted: turned, method: "折り目の向きから 90° 回転")
        }
        return .init(raw: raw, converted: raw, method: "変換なし")
    }
}
