import UIKit

/// 機種ごとの「画面の実寸」と「フロントカメラの位置」。
///
/// UIKit からは物理寸法が取れないので、実測した値を `table` に機種ID（hw.machine）で足していく。
/// 表にない機種は現行の近似（画面の短辺 65mm）にフォールバックする。
/// 実測値はまだ未取得。差し替えるときは `table` に1行足すだけでよい。
struct HologramDeviceProfile {
    /// 実測値の1件分
    struct Entry {
        /// 画面の mm/pt（クレジットカード 85.60mm に合わせて計測パネルで測った値）
        var mmPerPt: Double
        /// 上パネルの上端から、カメラのレンズ中心までの距離（mm。上端より上が正）
        var cameraAboveTopEdgeMM: Double
        /// 画面の横中央から、カメラのレンズ中心までの距離（mm。右が正）
        var cameraRightMM: Double
    }

    /// 実測済みの機種。例：  "iPhone18,1": Entry(mmPerPt: 0.0, cameraAboveTopEdgeMM: 6, cameraRightMM: 0),
    static let table: [String: Entry] = [:]

    /// 未実測の機種で使う近似
    static let fallbackShortSideMeters: Float = 0.065
    static let fallbackCameraAboveTopEdgeMM: Double = 8
    static let fallbackCameraRightMM: Double = 0

    let machineID: String
    let entry: Entry?

    /// 実測値が無く、近似で動いているか
    var isFallback: Bool { entry == nil }

    /// カメラの位置（上パネル座標、メートル）。上端中央からの差：x は右、y は上端より上。
    var cameraAboveTopEdge: Float { Float((entry?.cameraAboveTopEdgeMM ?? Self.fallbackCameraAboveTopEdgeMM) / 1000) }
    var cameraRight: Float { Float((entry?.cameraRightMM ?? Self.fallbackCameraRightMM) / 1000) }

    /// 1pt が何メートルか。実測値が無ければ「短辺 = 65mm」になる尺度。
    func metersPerPoint(boundsShortSide: CGFloat) -> Float {
        if let entry { return Float(entry.mmPerPt / 1000) }
        return Self.fallbackShortSideMeters / Float(max(boundsShortSide, 1))
    }

    static func current() -> HologramDeviceProfile {
        let id = readMachineID()
        return HologramDeviceProfile(machineID: id, entry: table[id])
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
