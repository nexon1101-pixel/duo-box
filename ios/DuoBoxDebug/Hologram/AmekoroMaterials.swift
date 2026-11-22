import SceneKit

/// amekoro.usdz の材質を名前で直す。USDZ 自体は差し替えない（41MB が履歴に増えるため）。
/// - Hair_B_Beret_OFF：PMX では不透明度0（非表示）だが、変換で値が落ちて Hair_B と同じ位置に重なって描かれる → 描画しない
/// - Hair_trans：PMX の不透明度 0.7 に戻す
enum AmekoroMaterials {
    static let hiddenName = "mt_amakoro_Hair_B_Beret_OFF"
    static let translucentName = "mt_amakoro_Hair_trans"
    static let translucentOpacity: CGFloat = 0.7

    /// 見つかった対象の材質名の数（0〜2）と、モデルの材質の総数（同じ材質の共有は1つと数える）
    struct Stats {
        var found: Int
        var total: Int
    }

    /// `root` 以下のすべてのジオメトリの材質を調べて直す。
    @discardableResult
    static func apply(to root: SCNNode) -> Stats {
        var seen = Set<ObjectIdentifier>()
        var foundNames = Set<String>()
        root.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                guard seen.insert(ObjectIdentifier(material)).inserted else { continue }
                switch material.name ?? "" {
                case hiddenName:
                    // 色もデプスも書かない＝見えない（Hair_B との Z ファイティングが消える）
                    material.colorBufferWriteMask = []
                    material.writesToDepthBuffer = false
                    material.readsFromDepthBuffer = false
                    foundNames.insert(hiddenName)
                case translucentName:
                    material.transparency = translucentOpacity
                    foundNames.insert(translucentName)
                default:
                    break
                }
            }
        }
        return Stats(found: foundNames.count, total: seen.count)
    }
}
