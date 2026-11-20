import DuoRemoteCore
import SwiftUI

/// DuoBox の入り口。ホームにモジュールが並び、選んだ機能の画面へ入る。
/// 機能を増やすときは、ここにカードと画面を足す。
struct RootView: View {
    @EnvironmentObject private var session: RemoteSession
    @State private var screen: Screen = .home

    enum Screen {
        case home, remote, keyboard
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            switch screen {
            case .home:
                HomeView(onOpen: { screen = $0 })
            case .remote:
                remoteView
            case .keyboard:
                KeyboardInfoView()
            }

            // 接続中はリモート操作の邪魔をしないよう、戻るボタンを出さない
            // （接続中の戻りは、リモート画面の右上メニューの「ホームへ戻る」から行う）
            if screen != .home && !session.isConnectedOrReconnecting {
                Button {
                    screen = .home
                } label: {
                    Image(systemName: "house.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(
                            Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                }
                .accessibilityLabel("ホームへ戻る")
                .padding(.trailing, 20)
                .padding(.bottom, 20)
                .zIndex(1)
            }
        }
    }

    /// リモート画面。右上メニューの「ホームへ戻る」で、接続したままホームへ戻れる。
    private var remoteView: some View {
        var view = ContentView()
        view.onExitToHome = { screen = .home }
        return view
    }
}

/// 画面全体の背景。アイコンと同じ、濃い紺にシアンと紫の光がにじむ感じ。
private struct BoxBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.02, green: 0.03, blue: 0.07)
            RadialGradient(
                colors: [Color.cyan.opacity(0.20), .clear],
                center: .topLeading, startRadius: 0, endRadius: 420
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.22), .clear],
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
                        colors: [.cyan, Color(red: 0.55, green: 0.45, blue: 1.0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            Text("LAUNCHER")
                .font(.caption.weight(.semibold))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

private struct HomeView: View {
    var onOpen: (RootView.Screen) -> Void

    var body: some View {
        ZStack {
            BoxBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Wordmark()
                        .padding(.top, 40)

                    VStack(spacing: 14) {
                        moduleCard(
                            title: "リモート",
                            detail: "PCの画面を見て、操作する",
                            systemImage: "display",
                            colors: [.cyan, .blue]
                        ) { onOpen(.remote) }
                        moduleCard(
                            title: "キーボード",
                            detail: "DuoFlick を追加して使う",
                            systemImage: "keyboard",
                            colors: [.purple, Color(red: 0.85, green: 0.35, blue: 1.0)]
                        ) { onOpen(.keyboard) }
                    }

                    Spacer(minLength: 12)

                    Text(versionText)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? ""
        return "DuoBox \(version)"
    }

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

/// 同梱キーボード（DuoFlick）の案内。キーボード自体の設定は、キーボード内の設定画面で行う。
private struct KeyboardInfoView: View {
    var body: some View {
        ZStack {
            BoxBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: "keyboard")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 48, height: 48)
                            .background(
                                LinearGradient(
                                    colors: [.purple, Color(red: 0.85, green: 0.35, blue: 1.0)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                            )
                        Text("キーボード")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .padding(.top, 56)

                    Text("このアプリに、DuoFlick のキーボードが入っています。使うには、iPhone の設定でキーボードを追加してください。")
                        .foregroundStyle(.white.opacity(0.85))

                    VStack(alignment: .leading, spacing: 12) {
                        step("1", "設定アプリを開く")
                        step("2", "一般 → キーボード → キーボード の順に進む")
                        step("3", "「新しいキーボードを追加」から DuoFlick を選ぶ")
                        step("4", "追加した DuoFlick を開いて「フルアクセスを許可」をオンにする（単語登録や設定の保存に必要です）")
                    }

                    Text("レイアウトや変換の調整は、キーボードを出して、その中にある設定画面で行います。")
                        .foregroundStyle(.white.opacity(0.85))

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("設定アプリを開く")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .background(
                                LinearGradient(
                                    colors: [.purple, Color(red: 0.85, green: 0.35, blue: 1.0)],
                                    startPoint: .leading, endPoint: .trailing
                                ),
                                in: Capsule()
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
    }

    private func step(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.8), Color(red: 0.85, green: 0.35, blue: 1.0).opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    in: Circle()
                )
            Text(text)
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
