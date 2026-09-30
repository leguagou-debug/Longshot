import Foundation
import CoreGraphics
import Accelerate

/// 一张图的「行指纹」。
///
/// 每行横向切成 `blocks` 个块，每块记录两个通道：
/// - 灰度均值：耐混叠（相对单点采样）
/// - 水平梯度均值：关键 —— 降采样后文字行会被白底平均掉，
///   只有均值时文字行与空白行几乎无法区分；梯度保留了「这一行有没有内容」。
///
/// 比对因此变成纯整数运算，速度足够在手机上实时处理几十张截图。
struct RowPrint {
    /// 行数
    let height: Int
    /// 每行分块数
    let blocks: Int
    /// 每行的字节数（blocks * 2）
    let stride: Int
    /// 原始数据，长度 = height * stride
    let data: [UInt8]

    init(height: Int, blocks: Int, data: [UInt8]) {
        self.height = height
        self.blocks = blocks
        self.stride = blocks * 2
        self.data = data
    }

    /// 单行纹理强度。0 表示纯色行（不携带信息），越大表示内容越丰富。
    @inline(__always)
    func rowTexture(_ y: Int) -> Int {
        let o = y * stride
        var minV = 255, maxV = 0, grad = 0
        for b in 0..<blocks {
            let v = Int(data[o + b * 2])
            if v < minV { minV = v }
            if v > maxV { maxV = v }
            grad += Int(data[o + b * 2 + 1])
        }
        return (maxV - minV) + (grad / blocks) * 2
    }

    /// 低于此值视为空白行
    static let textureMin = 6
}

/// 两行之间的归一化平方距离。0 = 完全一致。
@inline(__always)
func rowDistance(_ p: RowPrint, _ py: Int, _ q: RowPrint, _ qy: Int) -> Double {
    let s = p.stride
    let a = py * s, b = qy * q.stride
    var sum = 0
    for i in 0..<s {
        let d = Int(p.data[a + i]) - Int(q.data[b + i])
        sum += d * d
    }
    return Double(sum) / Double(s)
}

/// 把位图转成行指纹。
///
/// - Parameters:
///   - x0f/x1f: 横向取样范围（比例）。默认留 2% 边距避开圆角和滚动条。
///   - blocks: 分块数。
enum RowPrintBuilder {

    /// 灰度数据 + 尺寸
    struct Gray {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// 把 CGImage 画进灰度缓冲。
    ///
    /// 用 CoreGraphics 的灰度色彩空间，避免手写 RGBA 加权。
    static func gray(from image: CGImage) -> Gray? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let ok: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: w,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return Gray(pixels: buffer, width: w, height: h)
    }

    /// 构建行指纹。
    static func build(from image: CGImage,
                      x0f: Double = 0.02,
                      x1f: Double = 0.98,
                      blocks: Int) -> RowPrint? {
        guard let g = gray(from: image) else { return nil }
        return build(from: g, x0f: x0f, x1f: x1f, blocks: blocks)
    }

    static func build(from g: Gray,
                      x0f: Double = 0.02,
                      x1f: Double = 0.98,
                      blocks: Int) -> RowPrint? {
        let w = g.width, h = g.height
        guard w > 0, h > 0, blocks > 0 else { return nil }

        let x0 = max(0, min(w - 1, Int((Double(w) * x0f).rounded())))
        let x1 = max(x0 + 1, min(w, Int((Double(w) * x1f).rounded())))
        let sw = x1 - x0
        guard sw > 0 else { return nil }

        var out = [UInt8](repeating: 0, count: h * blocks * 2)

        for y in 0..<h {
            let rowBase = y * w + x0
            let o = y * blocks * 2
            for b in 0..<blocks {
                let bx0 = b * sw / blocks
                let bx1 = (b + 1) * sw / blocks
                var sum = 0
                var gradSum = 0
                var gradCount = 0
                var prev = Int(g.pixels[rowBase + bx0])
                for x in bx0..<bx1 {
                    let v = Int(g.pixels[rowBase + x])
                    sum += v
                    if x > bx0 {
                        gradSum += abs(v - prev)
                        gradCount += 1
                    }
                    prev = v
                }
                let count = max(1, bx1 - bx0)
                out[o + b * 2] = UInt8(clamping: sum / count)
                let gAvg = gradCount > 0 ? gradSum / gradCount : 0
                // 梯度通道放大 4 倍，让它在与均值同一量级上参与比对
                out[o + b * 2 + 1] = UInt8(clamping: min(255, gAvg * LongshotEngine.gradientScale))
            }
        }
        return RowPrint(height: h, blocks: blocks, data: out)
    }

    /// 把图缩放到指定最长边，返回新的 CGImage。
    /// 用 high 插值质量，保证指纹稳定。
    static func scaled(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let w = image.width, h = image.height
        let m = max(w, h)
        guard m > maxDimension else { return image }
        let k = Double(maxDimension) / Double(m)
        let nw = max(1, Int((Double(w) * k).rounded()))
        let nh = max(1, Int((Double(h) * k).rounded()))
        return resized(image, width: nw, height: nh)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let hasAlpha = image.alphaInfo != .none && image.alphaInfo != .noneSkipFirst
        let bitmapInfo = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let ctx = CGContext(data: nil,
                                  width: width, height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
