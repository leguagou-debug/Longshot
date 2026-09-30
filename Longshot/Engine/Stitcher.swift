import Foundation
import CoreGraphics
import UIKit

/// 把拼接方案渲染成一张长图。
enum Stitcher {

    struct Result {
        let image: CGImage
        /// 因为超出画布上限而被降低分辨率
        let downscaled: Bool
        let width: Int
        let height: Int
        /// 每一段在输出中的 Y 起点（用于画接缝标记）
        let seams: [Int]
    }

    /// 画布上限。iOS 上单张位图有硬上限，
    /// 超过会直接分配失败或渲染出黑图，所以必须提前降分辨率。
    static let maxArea = 16_000_000
    static let maxDimension = 16_384

    /// 合成。
    /// - Parameter quality: 输出宽度倍率（1 = 原宽）
    static func render(images: [CGImage],
                       plan: LongshotEngine.Plan,
                       cropLeft: Int = 0,
                       cropRight: Int = 0,
                       quality: Double = 1.0,
                       horizontal: Bool = false) -> Result? {

        let n = min(images.count, plan.outputs.count)
        guard n > 0 else { return nil }

        var baseW = 0
        for i in 0..<n { baseW = max(baseW, images[i].width) }

        // 左右裁切按「裁掉量」换算
        let l = max(0, min(cropLeft, max(0, baseW - 8)))
        let r = max(0, min(cropRight, max(0, baseW - l - 8)))
        let usableW = baseW - l - r
        guard usableW > 0 else { return nil }

        var outW = max(160, min(4096, Int((Double(usableW) * quality).rounded())))
        var totalH = 0
        var scaleOut = [Double](repeating: 1, count: n)
        var drawH = [Int](repeating: 1, count: n)

        func layout() {
            totalH = 0
            for i in 0..<n {
                scaleOut[i] = Double(outW) / Double(usableW)
                drawH[i] = max(1, Int((Double(plan.outputs[i].keepEnd - plan.outputs[i].keepStart) * scaleOut[i]).rounded()))
                totalH += drawH[i]
            }
        }
        layout()

        var downscaled = false
        if outW * totalH > maxArea {
            let f = sqrt(Double(maxArea) / Double(outW * totalH)) * 0.99
            outW = max(80, Int(Double(outW) * f))
            layout(); downscaled = true
        }
        if totalH > maxDimension {
            let f = Double(maxDimension) / Double(totalH) * 0.99
            outW = max(80, Int(Double(outW) * f))
            layout(); downscaled = true
        }
        guard outW > 0, totalH > 0 else { return nil }

        // 竖向合成
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: outW, height: totalH,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: totalH))

        // CoreGraphics 原点在左下，而我们按「从上到下」计算，所以逐段翻 Y
        var seams: [Int] = []
        var dyTop = 0
        for i in 0..<n {
            let o = plan.outputs[i]
            let srcW = images[i].width
            let srcH = images[i].height

            // 计算源图内的取样矩形，并做边界收口
            let sx = max(0, min(l, srcW - 1))
            let sw = max(1, min(usableW, srcW - sx))
            let sy = max(0, min(o.keepStart, srcH - 1))
            let sh = max(1, min(o.keepEnd - o.keepStart, srcH - sy))

            let dh = drawH[i]
            let dw = max(1, Int((Double(sw) * scaleOut[i]).rounded()))
            // 目标矩形的 Y（左上原点）
            let rectTop = dyTop
            let rectBottom = dyTop + dh
            // 转成 CG 的左下原点
            let cgY = totalH - rectBottom

            if let sub = images[i].cropping(to: CGRect(x: sx, y: sy, width: sw, height: sh)) {
                ctx.draw(sub, in: CGRect(x: 0, y: cgY, width: dw, height: dh))
            }

            // 接缝软融合：把当前图重叠区顶部若干行，用渐变盖回上一张尾部
            let F = min(o.feather, max(0, o.s), max(0, o.keepStart - o.c))
            if i > 0, F > 0, dyTop > 0 {
                let fh = max(1, Int((Double(F) * scaleOut[i]).rounded()))
                let fSy = o.keepStart - F
                if fSy >= 0, fh <= dyTop {
                    if let feathImg = images[i].cropping(to: CGRect(x: sx, y: fSy, width: sw, height: F)) {
                        drawFeathered(ctx: ctx, image: feathImg,
                                      x: 0, topY: dyTop - fh, width: dw, height: fh,
                                      totalHeight: totalH)
                    }
                }
            }

            dyTop += dh
            if i > 0 { seams.append(dyTop) }
        }

        guard let strip = ctx.makeImage() else { return nil }

        // 横向：整条逆时针旋转 90°
        if horizontal {
            guard let hctx = CGContext(data: nil,
                                       width: totalH, height: outW,
                                       bitsPerComponent: 8,
                                       bytesPerRow: 0,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            hctx.interpolationQuality = .high
            hctx.translateBy(x: 0, y: CGFloat(outW))
            hctx.rotate(by: -.pi / 2)
            hctx.draw(strip, in: CGRect(x: 0, y: 0, width: totalH, height: outW))
            if let rotated = hctx.makeImage() {
                return Result(image: rotated, downscaled: downscaled,
                              width: rotated.width, height: rotated.height,
                              seams: seams.map { _ in 0 })
            }
        }

        return Result(image: strip, downscaled: downscaled,
                      width: strip.width, height: strip.height, seams: seams)
    }

    /// 带水平渐变的软融合。
    /// 上方透明、下方不透明，让接缝处自然过渡。
    private static func drawFeathered(ctx: CGContext, image: CGImage,
                                      x: Int, topY: Int, width: Int, height: Int,
                                      totalHeight: Int) {
        guard height > 0, width > 0 else { return }
        guard let layer = CGContext(data: nil,
                                    width: width, height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        layer.interpolationQuality = .high
        layer.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // 只保留渐变覆盖的部分
        layer.setBlendMode(.destinationIn)
        // CG 原点在左下，所以「顶部透明」要放在高 Y
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [CGColor(red: 0, green: 0, blue: 0, alpha: 0),
                                           CGColor(red: 0, green: 0, blue: 0, alpha: 0.55),
                                           CGColor(red: 0, green: 0, blue: 0, alpha: 1)] as CFArray,
                                  locations: [0, 0.5, 1])
        if let g = gradient {
            layer.drawLinearGradient(g,
                                     start: CGPoint(x: 0, y: CGFloat(height)),
                                     end: CGPoint(x: 0, y: 0),
                                     options: [])
        }
        if let feathered = layer.makeImage() {
            let cgY = totalHeight - (topY + height)
            ctx.draw(feathered, in: CGRect(x: x, y: cgY, width: width, height: height))
        }
    }
}
