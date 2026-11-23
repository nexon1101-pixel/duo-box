import SwiftUI

/// 上下左右へ 0.5mm ずつ動かすボタン。move は (右へ mm, 下へ mm)
struct CalibrationNudgePad: View {
    static let stepMM: Double = 0.5
    let move: (_ rightMM: Double, _ downMM: Double) -> Void

    var body: some View {
        VStack(spacing: 4) {
            button("chevron.up", "上へ 0.5mm") { move(0, -Self.stepMM) }
            HStack(spacing: 4) {
                button("chevron.left", "左へ 0.5mm") { move(-Self.stepMM, 0) }
                Text("0.5mm").font(.caption2).frame(width: 48)
                button("chevron.right", "右へ 0.5mm") { move(Self.stepMM, 0) }
            }
            button("chevron.down", "下へ 0.5mm") { move(0, Self.stepMM) }
        }
    }

    private func button(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 44, height: 36)
                .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(label)
    }
}

/// G2：アプリが思っているカメラの位置に輪を出し、実物のカメラの点へ合わせる画面。
struct HologramCameraAlignView: View {
    @ObservedObject var diagnostics: HologramDiagnostics
    /// 決定したあとに呼ぶ
    var onDecide: () -> Void
    var onCancel: () -> Void

    @State private var belowTopMM: Double = HologramDeviceProfile.defaultCameraBelowTopMM
    @State private var rightMM: Double = HologramDeviceProfile.defaultCameraRightMM
    /// 「occlusion の値に戻す」を選んだ状態。決定すると手で合わせた値を消す
    @State private var useOcclusion = false
    @State private var loaded = false
    @State private var dragStart: (below: Double, right: Double)?

    private var mmPerPt: Double { HologramDeviceProfile.mmPerPoint }

    var body: some View {
        GeometryReader { geo in
            let profileFold = diagnostics.cameraProfile.foldYPt
            let fold = profileFold > 0 ? profileFold : geo.size.height / 2
            ZStack(alignment: .topLeading) {
                Color.black

                // 上パネル全体をドラッグの受け口にする（指で輪を隠さないため、動かした分だけ輪が動く）
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: geo.size.width, height: fold)
                    .gesture(dragGesture(width: geo.size.width, fold: fold))

                Circle()
                    .strokeBorder(.yellow, lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .overlay(Circle().fill(.yellow).frame(width: 3, height: 3))
                    .position(x: geo.size.width / 2 + rightMM / mmPerPt, y: belowTopMM / mmPerPt)
                    .allowsHitTesting(false)

                controls
                    .frame(width: geo.size.width, height: max(geo.size.height - fold, 0))
                    .offset(y: fold)
            }
        }
        .ignoresSafeArea()
        .foregroundStyle(.white)
        .onAppear(perform: loadCurrent)
    }

    private var controls: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("画面を斜めから見ると、カメラの点が見えます。輪をその点に合わせてください")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(HologramDeviceProfile.cameraPositionText(belowTopMM: belowTopMM, rightMM: rightMM))
                    .font(.system(.footnote, design: .monospaced))
                    .multilineTextAlignment(.center)
                CalibrationNudgePad { right, down in
                    rightMM += right
                    belowTopMM = max(belowTopMM + down, 0)
                    useOcclusion = false
                }
                HStack {
                    Button("occlusion の値に戻す", action: resetToOcclusion)
                        .disabled(diagnostics.cameraProfile.occlusionBelowTopMM == nil)
                    Button("左右を反転した値にする") {
                        rightMM = -rightMM
                        useOcclusion = false
                    }
                }
                .font(.caption)
                HStack(spacing: 24) {
                    Button("やめる", action: onCancel)
                    Button("決定", action: decide).bold()
                }
            }
            .padding(14)
        }
    }

    private func dragGesture(width: CGFloat, fold: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? (below: belowTopMM, right: rightMM)
                dragStart = start
                let halfWidthMM = Double(width) / 2 * mmPerPt
                rightMM = min(max(start.right + Double(value.translation.width) * mmPerPt, -halfWidthMM), halfWidthMM)
                belowTopMM = min(max(start.below + Double(value.translation.height) * mmPerPt, 0), Double(fold) * mmPerPt)
                useOcclusion = false
            }
            .onEnded { _ in dragStart = nil }
    }

    private func loadCurrent() {
        guard !loaded else { return }
        loaded = true
        belowTopMM = diagnostics.cameraProfile.cameraBelowTopMM
        rightMM = diagnostics.cameraProfile.cameraRightMM
    }

    private func resetToOcclusion() {
        let p = diagnostics.cameraProfile
        guard let below = p.occlusionBelowTopMM, let right = p.occlusionRightMM else { return }
        belowTopMM = below
        rightMM = right
        useOcclusion = true
    }

    private func decide() {
        if useOcclusion {
            diagnostics.clearManualCamera()
        } else {
            diagnostics.saveManualCamera(belowTopMM: belowTopMM, rightMM: rightMM)
        }
        onDecide()
    }
}
