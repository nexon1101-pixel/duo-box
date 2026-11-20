import GuestHostCore
import SwiftUI

/// Android の画面。GuestDisplayView（本元 GuestHost の Metal ビュー）を全面に出し、
/// 起動中・失敗・終了の表示と「戻る」を重ねる。入力は触れた所がそのままゲストのタッチになる（作り込みは段5）
struct AndroidSessionView: View {
    @StateObject private var runner = AndroidRunner()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // 表示は常に木に置く。ランタイムはこのビューに描く（起動前の失敗でも置いたままでよい）
            GuestDisplayView(scale: .points) { [runner] view, geometry in
                runner.viewDidLayout(view, geometry)
            }
            .ignoresSafeArea()

            overlay
        }
        .overlay(alignment: .topLeading) { backButton }
        .statusBarHidden(runner.phase == .running)
        .onChange(of: runner.phase) { _, phase in
            if case .ended(byUser: true) = phase { dismiss() }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        switch runner.phase {
        case .waiting, .booting:
            statusPanel {
                ProgressView().tint(.white)
                Text("Android を起動しています…")
                    .font(.headline)
                Text("解釈実行のため、最初の起動には数分かかることがあります")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                Text("パソコンから: \(runner.adbConnectHint)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .textSelection(.enabled)
                consoleView
                shareLogButton
            }
        case .stopping:
            statusPanel {
                ProgressView().tint(.white)
                Text("停止しています…")
                    .font(.headline)
            }
        case .failed(let reason):
            statusPanel {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("Android を起動できませんでした")
                    .font(.headline)
                Text(reason)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                consoleView
                shareLogButton
                Button("戻る") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .ended(byUser: false):
            statusPanel {
                Text("Android が終了しました")
                    .font(.headline)
                consoleView
                shareLogButton
                Button("戻る") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        case .running, .ended(byUser: true):
            EmptyView()
        }
    }

    /// ログの共有ボタン。状態・理由・コンソール末尾をまとめた文を共有シートへ出す
    private var shareLogButton: some View {
        ShareLink(item: runner.reportText) {
            Label("ログを共有", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
    }

    /// 起動中・失敗時だけ出す、ゲストのコンソールの末尾（原因調べ用）
    @ViewBuilder
    private var consoleView: some View {
        if !runner.consoleTail.isEmpty {
            ScrollView {
                Text(String(runner.consoleTail.suffix(1500)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        }
    }

    private func statusPanel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 14) { content() }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92).ignoresSafeArea())
    }

    /// 画面から戻る入口。ゲストを止めてから閉じる（起動前・失敗・終了後はすぐ閉じる）
    private var backButton: some View {
        Button {
            switch runner.phase {
            case .waiting, .booting, .running:
                runner.stop()
                if case .ended = runner.phase { dismiss() }
            case .stopping:
                break
            case .failed, .ended:
                dismiss()
            }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.45))
                .padding(8)
        }
        .disabled(runner.phase == .stopping)
        .opacity(runner.phase == .running ? 0.5 : 1)
    }
}
