import SwiftUI

/// デバッグ版の箱。中身（モジュール）はまだ入れず、器だけを用意した状態。
/// 試したいモジュールが出てきたら、ここにカードと画面を足していく。
struct HomeView: View {
    var body: some View {
        ZStack {
            BoxBackground()
            VStack(alignment: .leading, spacing: 28) {
                Wordmark()
                Spacer()
                Text("まだ何も入っていません")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
                Text(versionText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let name = info?["CFBundleDisplayName"] as? String ?? "DuoBox Debug"
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return "\(name) \(version)"
    }
}

/// 画面全体の背景。本番と同じ作りで、色だけ赤系。
private struct BoxBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.07)
            RadialGradient(
                colors: [Color.red.opacity(0.20), .clear],
                center: .topLeading, startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [Color.orange.opacity(0.22), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 460
            )
        }
        .ignoresSafeArea()
    }
}

/// 見出しのワードマーク。
private struct Wordmark: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DuoBox")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            Text("DEBUG")
                .font(.caption.weight(.semibold))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
