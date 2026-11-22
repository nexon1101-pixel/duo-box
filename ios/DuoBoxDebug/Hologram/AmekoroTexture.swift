import UIKit

/// 雨衣ちゃんの1枚絵。バンドルに amekoro.png があればそれを使い、無ければ実行時に簡易イラストを描く。
enum AmekoroTexture {
    static func load() -> UIImage {
        if let url = Bundle.main.url(forResource: "amekoro", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        if let image = UIImage(named: "amekoro") { return image }
        return drawProcedural()
    }

    /// 青系ツインテール＋顔の簡易イラスト（透過背景）。縦長 2:3。
    static func drawProcedural() -> UIImage {
        let size = CGSize(width: 512, height: 768)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let g = ctx.cgContext
            let hair = UIColor(red: 0.30, green: 0.55, blue: 0.95, alpha: 1)
            let hairDark = UIColor(red: 0.18, green: 0.35, blue: 0.75, alpha: 1)
            let skin = UIColor(red: 1.0, green: 0.90, blue: 0.84, alpha: 1)
            let dress = UIColor(red: 0.92, green: 0.95, blue: 1.0, alpha: 1)

            // ツインテール（頭の後ろ、左右に長く垂らす）
            hairDark.setFill()
            g.fillEllipse(in: CGRect(x: 20, y: 150, width: 150, height: 480))
            g.fillEllipse(in: CGRect(x: 342, y: 150, width: 150, height: 480))
            hair.setFill()
            g.fillEllipse(in: CGRect(x: 40, y: 150, width: 120, height: 440))
            g.fillEllipse(in: CGRect(x: 352, y: 150, width: 120, height: 440))

            // 体（ワンピース）
            dress.setFill()
            let body = UIBezierPath()
            body.move(to: CGPoint(x: 200, y: 450))
            body.addLine(to: CGPoint(x: 312, y: 450))
            body.addLine(to: CGPoint(x: 360, y: 720))
            body.addLine(to: CGPoint(x: 152, y: 720))
            body.close()
            body.fill()
            // 腕と脚の代わりに小さな足元
            skin.setFill()
            g.fillEllipse(in: CGRect(x: 190, y: 715, width: 50, height: 34))
            g.fillEllipse(in: CGRect(x: 272, y: 715, width: 50, height: 34))

            // 頭の後ろ髪 → 顔 → 前髪
            hair.setFill()
            g.fillEllipse(in: CGRect(x: 120, y: 60, width: 272, height: 300))
            skin.setFill()
            g.fillEllipse(in: CGRect(x: 145, y: 130, width: 222, height: 250))
            hair.setFill()
            let bangs = UIBezierPath()
            bangs.move(to: CGPoint(x: 135, y: 220))
            bangs.addQuadCurve(to: CGPoint(x: 377, y: 220), controlPoint: CGPoint(x: 256, y: 20))
            bangs.addLine(to: CGPoint(x: 340, y: 215))
            bangs.addLine(to: CGPoint(x: 300, y: 170))
            bangs.addLine(to: CGPoint(x: 256, y: 215))
            bangs.addLine(to: CGPoint(x: 210, y: 170))
            bangs.addLine(to: CGPoint(x: 172, y: 215))
            bangs.close()
            bangs.fill()

            // 目（青い瞳＋ハイライト）
            for cx: CGFloat in [205, 307] {
                UIColor.white.setFill()
                g.fillEllipse(in: CGRect(x: cx - 26, y: 258, width: 52, height: 64))
                UIColor(red: 0.15, green: 0.35, blue: 0.85, alpha: 1).setFill()
                g.fillEllipse(in: CGRect(x: cx - 20, y: 266, width: 40, height: 52))
                UIColor(red: 0.05, green: 0.1, blue: 0.3, alpha: 1).setFill()
                g.fillEllipse(in: CGRect(x: cx - 10, y: 282, width: 20, height: 26))
                UIColor.white.setFill()
                g.fillEllipse(in: CGRect(x: cx - 14, y: 272, width: 12, height: 12))
            }
            // ほっぺと口
            UIColor(red: 1.0, green: 0.62, blue: 0.68, alpha: 0.6).setFill()
            g.fillEllipse(in: CGRect(x: 160, y: 330, width: 36, height: 20))
            g.fillEllipse(in: CGRect(x: 316, y: 330, width: 36, height: 20))
            UIColor(red: 0.75, green: 0.30, blue: 0.35, alpha: 1).setStroke()
            g.setLineWidth(5)
            g.setLineCap(.round)
            g.addArc(center: CGPoint(x: 256, y: 338), radius: 16,
                     startAngle: 0.25 * .pi, endAngle: 0.75 * .pi, clockwise: false)
            g.strokePath()

            // 髪飾り（ツインテールの根元）
            UIColor(red: 1.0, green: 0.85, blue: 0.3, alpha: 1).setFill()
            g.fillEllipse(in: CGRect(x: 92, y: 140, width: 36, height: 36))
            g.fillEllipse(in: CGRect(x: 384, y: 140, width: 36, height: 36))
        }
    }
}
