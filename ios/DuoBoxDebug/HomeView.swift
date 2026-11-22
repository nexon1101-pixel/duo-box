import SwiftUI

/// サンドボックス版の箱。中身（モジュール）はまだ入れず、器だけを用意した状態。
/// 試したいモジュールが出てきたら、ここにカードと画面を足していく。
struct HomeView: View {
    @State private var showHologram = false

    var body: some View {
        if showHologram {
            HologramView(onExit: { showHologram = false })
        } else {
            home
        }
    }

    private var home: some View {
        ZStack {
            BoxBackground()
            VStack(alignment: .leading, spacing: 28) {
                Wordmark()
                moduleCard(
                    title: "ホログラム",
                    detail: "雨衣ちゃんを箱の中に立たせる",
                    systemImage: "cube.transparent",
                    colors: [.red, .orange]
                ) { showHologram = true }
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
        let name = info?["CFBundleDisplayName"] as? String ?? "DuoBox Sandbox"
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return "\(name) \(version)"
    }

    /// 本番版 HomeView のカードと同じ見た目。
    private func moduleCard(title: String, detail: String, systemImage: String,
                            colors: [Color], action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )
                    .shadow(color: colors.first!.opacity(0.45), radius: 10, y: 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(18)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            Text("SANDBOX")
                .font(.caption.weight(.semibold))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
