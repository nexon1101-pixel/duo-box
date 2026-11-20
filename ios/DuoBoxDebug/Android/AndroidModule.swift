import SwiftUI

/// 箱のホームに出す「Android」の入口。タップで Android の画面を全画面で開く。
/// ホーム側（HomeView）はこのカードを置くだけにして、Android の中身はこのフォルダに閉じる
struct AndroidEntryCard: View {
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "iphone.gen3")
                    .font(.title2)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Android")
                        .font(.headline)
                    Text("Kernarium で Android を起動します（実験中）")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(16)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .fullScreenCover(isPresented: $isPresented) {
            AndroidSessionView()
        }
    }
}
