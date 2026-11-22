import UIKit

/// iPhone Duo の「画面の実寸」と「内側カメラの位置」。
///
/// 実寸の出どころ（依頼者調べ）：開いた内側画面 157.7×110.9mm、951×669pt、1pt＝0.166mm。
/// ノート型の上下パネルは各 約111mm（幅）×79mm（高さ）。折り目の離れは折り角で変わる（foldGapMM(angleDeg:)）。
/// 内側カメラは画面内（上辺の中央寄り）で公開の mm 値がないため、UIKit の reserved region（.occlusion）から読む。
struct HologramDeviceProfile: Equatable {
    /// 1pt の実寸（mm）。依頼者調べの iPhone Duo 実寸
    static let mmPerPoint: Double = 0.166
    /// 折り目で上下の表示領域が離れる距離の上限（mm）。
    /// 実機で決めるための定数。根拠は曲げ部分の最大幅の記事値
    static let foldGapMaxMM: Double = 3.85
    /// 折り角（度）に対する離れの合計 G（mm）。180°で 0、90°以下で上限
    static func foldGapMM(angleDeg: Double) -> Double {
        foldGapMaxMM * min(max((180 - angleDeg) / 90, 0), 1)
    }
    /// ヒンジ軸から上下パネルそれぞれの折り目側の端までの距離（メートル）。G を半分ずつ振り分ける
    static func hingeToPanelEdge(angleDeg: Double) -> Float {
        Float(foldGapMM(angleDeg: angleDeg) / 2 / 1000)
    }
    /// occlusion が取れないときのカメラ位置：上パネルの上端から下へ 4mm、横中央
    static let defaultCameraBelowTopMM: Double = 4
    static let defaultCameraRightMM: Double = 0

    /// カメラ位置をどこから得たか
    enum CameraSource: Equatable {
        case occlusion    // reserved region から読めた（上パネル側）
        case fallback     // 取れないので既定値
        case lowerPanel   // カメラが下パネル側。補正せず既定値で動かし、パネルで向きの変更を促す
    }

    let machineID: String
    var cameraSource: CameraSource = .fallback
    /// 目の位置の計算に使うカメラ位置（mm）：上パネルの上端から下への距離／画面の横中央からの差（右が正）
    var cameraBelowTopMM: Double = HologramDeviceProfile.defaultCameraBelowTopMM
    var cameraRightMM: Double = HologramDeviceProfile.defaultCameraRightMM
    /// 読み取った occlusion の中心（ビュー座標 pt）。取れなければ nil
    var cameraCenterPt: CGPoint?
    /// 折り目の位置（ビュー座標 pt）
    var foldYPt: CGFloat = 0
    /// ビューの幅（pt）。横中央からの差の表示に使う
    var viewWidthPt: CGFloat = 0

    /// カメラの位置（メートル）
    var cameraBelowTop: Float { Float(cameraBelowTopMM / 1000) }
    var cameraRight: Float { Float(cameraRightMM / 1000) }
    /// 1pt が何メートルか
    var metersPerPoint: Float { Float(Self.mmPerPoint / 1000) }

    /// occlusion の frame と折り目の位置から、カメラ位置を決めたプロファイルを返す
    func resolved(occlusion: CGRect?, foldY: CGFloat, viewSize: CGSize) -> HologramDeviceProfile {
        var p = HologramDeviceProfile(machineID: machineID)
        p.foldYPt = foldY
        p.viewWidthPt = viewSize.width
        guard let occlusion else { return p }
        let center = CGPoint(x: occlusion.midX, y: occlusion.midY)
        guard center.x.isFinite, center.y.isFinite else { return p }
        p.cameraCenterPt = center
        if center.y > foldY {
            p.cameraSource = .lowerPanel      // 補正しない（位置は既定値のまま）
        } else {
            p.cameraSource = .occlusion
            p.cameraBelowTopMM = Double(center.y) * Self.mmPerPoint
            p.cameraRightMM = Double(center.x - viewSize.width / 2) * Self.mmPerPoint
        }
        return p
    }

    static func current() -> HologramDeviceProfile {
        HologramDeviceProfile(machineID: readMachineID())
    }

    static func readMachineID() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "不明" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
