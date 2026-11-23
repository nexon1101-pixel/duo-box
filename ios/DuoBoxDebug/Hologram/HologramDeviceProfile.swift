import UIKit

/// iPhone Duo の「画面の実寸」と「内側カメラの位置」。
///
/// 実寸の出どころ（依頼者調べ）：開いた内側画面 157.7×110.9mm、951×669pt、1pt＝0.166mm。
/// ノート型の上下パネルは各 約111mm（幅）×79mm（高さ）。折り目の離れは折り角で変わる（foldGapMM(angleDeg:)）。
/// 内側カメラは画面内（上辺の中央寄り）で公開の mm 値がないため、UIKit の reserved region（.occlusion）から読む。
struct HologramDeviceProfile: Equatable {
    /// 1pt の実寸（mm）。依頼者調べの iPhone Duo 実寸
    static let mmPerPoint: Double = 0.166
    /// 曲げ部分の幅（mm）。記事値（曲げの空間は最も広い所で 3.85mm）を、曲げの直径とみなす
    static let foldGapMaxMM: Double = 3.85
    /// 折り角（度）に対する、平らな2枚とみなしたときの離れの合計 G（mm）。
    /// 画面は折り目で途切れず、半径 R の円弧に沿って曲がっている（画素は消えない）。
    /// 2枚の平面が交わる角を基準にすると、円弧の端（平らな部分の始まり）は角から R·tan(φ/2)、
    /// 画素の並びでは円弧の真ん中から R·φ/2 の位置にあるので、その差の2倍が G になる（φ＝180°−折り角）。
    /// 以前の「90°で 3.85mm」の置き方は離れを大きく取りすぎて、折り目で絵が切れて見えていた（90°でも約 0.8mm）
    static func foldGapMM(angleDeg: Double) -> Double {
        let r = foldGapMaxMM / 2
        let phi = min(max((180 - angleDeg) * .pi / 180, 0), 170 * .pi / 180)
        return 2 * r * (tan(phi / 2) - phi / 2)
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
        case manual       // 手で合わせた値（occlusion より優先）
    }

    /// 手で合わせたカメラ位置（mm）
    struct ManualCamera: Equatable {
        var belowTopMM: Double
        var rightMM: Double
    }

    /// カメラ位置を、左右を言葉にした文で返す
    static func cameraPositionText(belowTopMM: Double, rightMM: Double) -> String {
        let side: String
        if abs(rightMM) < 0.05 {
            side = "画面の中央"
        } else {
            side = "画面の中央から\(rightMM < 0 ? "左" : "右")へ \(String(format: "%.1f", abs(rightMM)))mm"
        }
        return "上パネルの上端から下へ \(String(format: "%.1f", belowTopMM))mm、\(side)"
    }

    let machineID: String
    var cameraSource: CameraSource = .fallback
    /// 目の位置の計算に使うカメラ位置（mm）：上パネルの上端から下への距離／画面の横中央からの差（右が正）
    var cameraBelowTopMM: Double = HologramDeviceProfile.defaultCameraBelowTopMM
    var cameraRightMM: Double = HologramDeviceProfile.defaultCameraRightMM
    /// 読み取った occlusion の中心（ビュー座標 pt）。取れなければ nil
    var cameraCenterPt: CGPoint?
    /// occlusion の生の frame（使ったもの）と、有効だった全部の frame（ビュー座標 pt）
    var occlusionFrame: CGRect?
    var occlusionFrames: [CGRect] = []
    /// 変換前の frame（occlusionFrames と同じ順）と、変換の根拠
    var occlusionRawFrame: CGRect?
    var occlusionRawFrames: [CGRect] = []
    var occlusionMethod: String?
    /// occlusion から計算した位置（mm）。上パネル側で読めたときだけ値が入る
    var occlusionBelowTopMM: Double?
    var occlusionRightMM: Double?
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
    /// 手で合わせた値（manual）があれば、それを occlusion より優先する
    func resolved(primary: HingeMonitor.OcclusionReading?, readings: [HingeMonitor.OcclusionReading] = [],
                  foldY: CGFloat, viewSize: CGSize,
                  manual: ManualCamera? = nil) -> HologramDeviceProfile {
        var p = HologramDeviceProfile(machineID: machineID)
        let occlusion = primary?.converted
        p.foldYPt = foldY
        p.viewWidthPt = viewSize.width
        p.occlusionFrame = occlusion
        p.occlusionFrames = readings.map(\.converted)
        p.occlusionRawFrame = primary?.raw
        p.occlusionRawFrames = readings.map(\.raw)
        p.occlusionMethod = primary?.method
        if let occlusion, occlusion.midX.isFinite, occlusion.midY.isFinite {
            let center = CGPoint(x: occlusion.midX, y: occlusion.midY)
            p.cameraCenterPt = center
            if center.y > foldY {
                p.cameraSource = .lowerPanel      // 補正しない（位置は既定値のまま）
            } else {
                p.cameraSource = .occlusion
                p.cameraBelowTopMM = Double(center.y) * Self.mmPerPoint
                p.cameraRightMM = Double(center.x - viewSize.width / 2) * Self.mmPerPoint
                p.occlusionBelowTopMM = p.cameraBelowTopMM
                p.occlusionRightMM = p.cameraRightMM
            }
        }
        if let manual {
            p.cameraSource = .manual
            p.cameraBelowTopMM = manual.belowTopMM
            p.cameraRightMM = manual.rightMM
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
