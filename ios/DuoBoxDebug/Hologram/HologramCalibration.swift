import Foundation

/// キャリブレーションで決まる値の保存先。機種ID（hw.machine）ごとに1つの辞書で持つ。
/// 調整値（hologram.tunes.v1）と p・w 記録（hologram.pwTable.v1）とは別のキーなので、互いに影響しない。
enum HologramCalibrationStore {
    private static func key(_ machineID: String) -> String { "hologram.calib.v2.\(machineID)" }

    private static func dictionary(_ machineID: String) -> [String: Any] {
        UserDefaults.standard.dictionary(forKey: key(machineID)) ?? [:]
    }

    private static func update(_ machineID: String, _ change: (inout [String: Any]) -> Void) {
        var d = dictionary(machineID)
        change(&d)
        UserDefaults.standard.set(d, forKey: key(machineID))
    }

    /// 保存された軸対応。無い・壊れているときは nil（呼び出し側は「そのまま」を使う）
    static func axisMap(machineID: String) -> HeadTracker.AxisMap? {
        guard let a = dictionary(machineID)["axis"] as? [Double], a.count == 4,
              a.allSatisfy({ $0.isFinite }) else { return nil }
        return HeadTracker.AxisMap(xAxis: min(max(Int(a[0]), 0), 2), xSign: a[1] < 0 ? -1 : 1,
                                   yAxis: min(max(Int(a[2]), 0), 2), ySign: a[3] < 0 ? -1 : 1)
    }

    static func saveAxisMap(_ m: HeadTracker.AxisMap, machineID: String) {
        update(machineID) {
            $0["axis"] = [Double(m.xAxis), Double(m.xSign), Double(m.yAxis), Double(m.ySign)]
        }
    }

    /// 手で合わせたカメラ位置（mm）。occlusion より優先する。無い・壊れているときは nil
    static func manualCamera(machineID: String) -> HologramDeviceProfile.ManualCamera? {
        let d = dictionary(machineID)
        guard let below = d["cameraBelowTopMM"] as? Double, let right = d["cameraRightMM"] as? Double,
              below.isFinite, right.isFinite else { return nil }
        return .init(belowTopMM: below, rightMM: right)
    }

    static func saveManualCamera(_ c: HologramDeviceProfile.ManualCamera, machineID: String) {
        update(machineID) {
            $0["cameraBelowTopMM"] = c.belowTopMM
            $0["cameraRightMM"] = c.rightMM
        }
    }

    static func clearManualCamera(machineID: String) {
        update(machineID) {
            $0.removeValue(forKey: "cameraBelowTopMM")
            $0.removeValue(forKey: "cameraRightMM")
        }
    }
}
