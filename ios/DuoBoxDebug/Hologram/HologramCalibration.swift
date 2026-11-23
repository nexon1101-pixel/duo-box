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

    /// G3 の計測を最後まで行ったか（手で軸対応を変えても、実施済みのまま）
    static func isCalibrated(machineID: String) -> Bool {
        dictionary(machineID)["calibrated"] as? Bool ?? false
    }

    /// G3 の結果の文（例：画面の右＝カメラの −y）
    static func resultText(machineID: String) -> String? {
        dictionary(machineID)["resultText"] as? String
    }

    static func saveMeasured(_ m: HeadTracker.AxisMap, resultText: String, machineID: String) {
        saveAxisMap(m, machineID: machineID)
        update(machineID) {
            $0["calibrated"] = true
            $0["resultText"] = resultText
        }
    }

    /// G4 の箱の確認の答え（未回答は nil）
    static func boxCheck(machineID: String) -> Bool? {
        dictionary(machineID)["boxCheck"] as? Bool
    }

    static func saveBoxCheck(_ v: Bool, machineID: String) {
        update(machineID) { $0["boxCheck"] = v }
    }

    /// 選んだ映像の向き（時計回りの 90° の数、0〜3）。無い・壊れているときは 0
    static func videoTurns(machineID: String) -> Int {
        guard let v = dictionary(machineID)["videoTurns"] as? Int, (0...3).contains(v) else { return 0 }
        return v
    }

    static func saveVideoTurns(_ turns: Int, machineID: String) {
        update(machineID) { $0["videoTurns"] = turns }
    }

    /// 向きが変わって無効になった計測結果を消す（カメラ位置と点の反転は残す）
    static func clearMeasured(machineID: String) {
        update(machineID) {
            $0.removeValue(forKey: "calibrated")
            $0.removeValue(forKey: "resultText")
            $0.removeValue(forKey: "boxCheck")
        }
    }

    /// 距離の倍率の範囲と刻み。目の位置（カメラから見た x・y・z）に同じ値を掛ける
    static let distanceScaleRange: ClosedRange<Double> = 0.6...1.6
    static let distanceScaleStep: Double = 0.01
    /// 先読みの範囲（ms）
    static let predictionRangeMS: ClosedRange<Double> = 0...120

    /// 範囲に収め、0.01 刻みにそろえる
    static func clampedDistanceScale(_ v: Double) -> Double {
        let c = min(max(v, distanceScaleRange.lowerBound), distanceScaleRange.upperBound)
        return (c / distanceScaleStep).rounded() * distanceScaleStep
    }

    /// 保存された距離の倍率。無い・壊れているときは 1
    static func distanceScale(machineID: String) -> Double {
        guard let v = dictionary(machineID)["distanceScale"] as? Double, v.isFinite else { return 1 }
        return clampedDistanceScale(v)
    }

    static func saveDistanceScale(_ v: Double, machineID: String) {
        update(machineID) { $0["distanceScale"] = clampedDistanceScale(v) }
    }

    /// この機種で保存した先読み（ms）。無いときは nil（調整値 hologram.tunes.v1 の値を使う）
    static func predictionMS(machineID: String) -> Double? {
        guard let v = dictionary(machineID)["predictionMS"] as? Double, v.isFinite else { return nil }
        return min(max(v, predictionRangeMS.lowerBound), predictionRangeMS.upperBound)
    }

    static func savePredictionMS(_ v: Double, machineID: String) {
        update(machineID) { $0["predictionMS"] = min(max(v, predictionRangeMS.lowerBound), predictionRangeMS.upperBound) }
    }

    /// 開発用：鏡映しの映像の上で、点だけをさらに左右反転する
    static func overlayFlip(machineID: String) -> Bool {
        dictionary(machineID)["overlayFlip"] as? Bool ?? false
    }

    static func saveOverlayFlip(_ v: Bool, machineID: String) {
        update(machineID) { $0["overlayFlip"] = v }
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
