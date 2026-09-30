import Foundation
import CoreGraphics

/// 长截图拼接引擎。
///
/// 整体流程与网页版一致，是我已经用逐像素比对验证过的算法：
/// 1. 行指纹降维（RowPrint）
/// 2. 探测固定状态栏 / 底部栏
/// 3. 逐对扫描重叠位移，按「峰对比度 + 参与行数」判置信
/// 4. 用「每屏步长恒定」这一物理约束消歧
/// 5. 汇总裁切窗口，保证接缝连续（keepStart = 上一张 keepEnd − step）
enum LongshotEngine {

    // MARK: - 可调参数

    /// 梯度通道放大倍数
    static let gradientScale = 4
    /// 全宽指纹分块数
    static let stripBlocks = 32
    /// 中部指纹分块数（用于固定栏探测）
    static let chromeBlocks = 16
    /// 分析用缩略图的最长边
    static let workMax = 1000
    /// 「源图」保留的最长边（最终渲染用）
    static let sourceMax = 2600

    /// 扫描下限：内容区高度的比例。
    /// Picsew 文档要求重叠区至少「两行字」≈3.5%，这里放到 1.5% 更宽松。
    static let overlapMinFrac = 0.015
    /// 扫描上限
    static let overlapMaxFrac = 0.80
    /// 可信区间下限
    static let overlapTrustFrac = 0.02
    /// 至少要比较这么多有内容的行
    static let minRows = 5
    /// 固定栏最多占高度比例（状态栏+导航≈9.5%，标签栏≈8%）
    static let chromeLimit = 0.16
    /// 固定栏至少覆盖这么多行
    static let minChromeRows = 5
    /// 其中至少有内容行数
    static let minChromeTex = 3

    /// 匹配灵敏度 1...5，默认 3
    static func chromeThreshold(sensitivity: Int) -> Double { 4 + Double(sensitivity) * 1.2 }

    // MARK: - 单张图的输入

    /// 待处理的一张截图。
    struct Input {
        /// 原始图（已按 sourceMax 限幅），用于最终渲染
        let image: CGImage
        /// 分析用缩略图的缩放系数（work / source）
        let k: Double
        /// 全宽行指纹
        let print: RowPrint
        /// 中部行指纹（避开状态栏左右两侧会变的内容）
        let chromePrint: RowPrint
        let width: Int
        let height: Int
    }

    // MARK: - 单张图的输出

    struct Output {
        /// 顶部固定栏高度（源图像素）
        var c = 0
        /// 底部固定栏高度（源图像素）
        var d = 0
        /// 与上一张的重叠位移（源图像素）
        var s = 0
        /// 保留区间起点（源图像素）
        var keepStart = 0
        /// 保留区间终点（源图像素）
        var keepEnd = 0
        /// 软融合宽度
        var feather = 0
        /// 置信度不足，建议用户手动确认
        var lowConfidence = false
        /// 疑似与上一张完全重复
        var duplicate = false
    }

    struct Plan {
        var outputs: [Output]
        /// 输出总高度（源图像素）
        var totalHeight: Int
        /// 共识步长（源图像素），供诊断
        var stepMedian: Int
        var lowCount: Int
        var dupCount: Int
    }

    // MARK: - 准备输入

    /// 把一张 CGImage 变成引擎输入。
    static func prepare(_ image: CGImage) -> Input? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }

        // 分析用缩略图
        let m = max(w, h)
        let k = m > workMax ? Double(workMax) / Double(m) : 1.0
        guard let work = (k < 1.0)
            ? RowPrintBuilder.resized(image, width: max(1, Int((Double(w) * k).rounded())),
                                            height: max(1, Int((Double(h) * k).rounded())))
            : image
        else { return nil }

        // 实际缩放系数（用真实像素算，避免舍入偏差）
        let realK = Double(work.height) / Double(h)

        guard let print = RowPrintBuilder.build(from: work, x0f: 0.02, x1f: 0.98,
                                               blocks: stripBlocks),
              // 固定栏检测带取 0.22~0.78：iOS 状态栏时钟在左、电量在右都会变，
              // 只取中间 1/3 又容易整段空白而漏检
              let chrome = RowPrintBuilder.build(from: work, x0f: 0.22, x1f: 0.78,
                                                 blocks: chromeBlocks)
        else { return nil }

        return Input(image: image, k: realK, print: print, chromePrint: chrome,
                     width: w, height: h)
    }

    // MARK: - 固定栏探测

    /// 探测顶部 / 底部固定栏高度（work 尺度像素）。
    ///
    /// 判据：相邻两张在同一位置存在「整段相同」的像素。
    /// 但不能要求每一行都有内容 —— 真实状态栏中部大量是纯白，
    /// 所以改为：允许平坦行通过，但整段内必须有足够多的有内容行。
    /// 同时底部固定栏不允许把「内容区留白」算进来，只认最后一个有内容行。
    static func detectChrome(_ pa: RowPrint, _ pb: RowPrint, sensitivity: Int) -> (top: Int, bot: Int) {
        let lim = min(pa.height, pb.height)
        let maxScan = Int(Double(lim) * chromeLimit)
        let thr = chromeThreshold(sensitivity: sensitivity)

        // 顶部：逐行往下
        var top = 0, run = 0, tex = 0, seen = 0
        var y = 0
        while y < maxScan {
            if rowDistance(pa, y, pb, y) <= thr {
                top = y + 1; run = 0; seen += 1
                if pa.rowTexture(y) > RowPrint.textureMin { tex += 1 }
            } else {
                run += 1
                if run >= 3 { break }
            }
            y += 1
        }

        // 底部：自最底行往上，边界取「最后一个有内容行」
        // 底栏内部的空白（图标与 home 指示条之间）和内容区留白都满足
        // 「两图相同」，仅凭像素无法区分；一见空白就停会让 d 严重低估，
        // 进而让 s 承担本属于 d 的偏差，低重叠时直接算错。
        var seenB = 0, texB = 0, cand = 0, candTex = 0
        run = 0
        var yb = 1
        while yb <= maxScan {
            let ia = pa.height - yb, ib = pb.height - yb
            if ia < top || ib < top { break }
            if rowDistance(pa, ia, pb, ib) <= thr {
                seenB += 1; run = 0
                if pa.rowTexture(ia) > RowPrint.textureMin || pb.rowTexture(ib) > RowPrint.textureMin {
                    texB += 1; cand = yb; candTex = texB
                }
            } else {
                run += 1
                if run >= 3 { break }
            }
            yb += 1
        }

        let okTop = seen >= minChromeRows && tex >= minChromeTex
        let okBot = cand >= minChromeRows && candTex >= minChromeTex
        return (top: (okTop && top >= 4) ? top : 0,
                bot: (okBot && cand >= 4) ? cand : 0)
    }

    // MARK: - 重叠匹配

    struct ShiftResult {
        var s: Int
        var score: Double
        var low: Bool
        var duplicate: Bool
        var candidates: [Int]
        var flat: Bool
        var contrast: Double
        var rows: Int
    }

    /// 重叠区打分。
    ///
    /// 关键：空白行不携带信息，白对白必然给出 0 残差，
    /// 若不剔除就会出现「整段留白 = 完美匹配」的假峰。
    /// 这里只统计双方至少一侧有内容的行，并按纹理强度加权；
    /// 一侧有内容另一侧空白视为强失配。
    static func overlapScore(_ a: Input, _ b: Input,
                             cA: Int, dA: Int, cB: Int, s: Int) -> (score: Double, rows: Int) {
        let hA = a.print.height
        let aStart = hA - dA - s
        let sample = 44
        let stride = max(1, s / sample)
        var sum = 0.0, wsum = 0.0, rows = 0

        var t = 0
        while t < s {
            let ay = aStart + t
            let by = cB + t
            if ay >= 0 && ay < hA - dA && by >= 0 && by < b.print.height {
                let ta = a.print.rowTexture(ay)
                let tb = b.print.rowTexture(by)
                let w = ta + tb
                if w > RowPrint.textureMin * 2 {
                    let d = rowDistance(a.print, ay, b.print, by)
                    let aTex = ta > RowPrint.textureMin * 2
                    let bTex = tb > RowPrint.textureMin * 2
                    let penal = (aTex != bTex) ? 220.0 : 0.0
                    sum += (d + penal) * Double(w)
                    wsum += Double(w)
                    rows += 1
                }
            }
            t += stride
        }
        return (wsum > 0 ? sum / wsum : 9999, rows)
    }

    /// 在扫描范围内寻找位移，返回候选与对比度。
    ///
    /// 置信判定不用「绝对残差」：两张图各自独立降采样后，
    /// 即便内容严格对应残差也不为 0；得分曲线的对比度才是可靠信号。
    static func findShift(_ a: Input, _ b: Input,
                          cA: Int, dA: Int, cB: Int, sensitivity: Int) -> ShiftResult {
        let contentH = min(a.print.height - cA - dA, b.print.height - cB)
        let sMax = Int(Double(contentH) * overlapMaxFrac)
        let sMin = max(6, Int((Double(contentH) * overlapMinFrac).rounded()))

        let empty = ShiftResult(s: 0, score: 9999, low: true, duplicate: false,
                                candidates: [], flat: false, contrast: 1, rows: 0)
        guard sMax > sMin + 2 else { return empty }
        guard contentH > 0 else { return empty }

        // 内容太平坦（纯白页）时不可能可靠匹配
        guard hasTexture(a.print, minRows: minRows), hasTexture(b.print, minRows: minRows) else {
            var r = empty; r.flat = true; return r
        }

        var scores = [Double](repeating: 1e9, count: sMax + 1)
        var rowsN = [Int](repeating: 0, count: sMax + 1)
        var best = 1e9, bestS = sMin

        for s in sMin...sMax {
            let r = overlapScore(a, b, cA: cA, dA: dA, cB: cB, s: s)
            scores[s] = r.score
            rowsN[s] = r.rows
            if r.score < best { best = r.score; bestS = s }
        }

        // 排除最优邻域后的次优，衡量峰有多突出
        let guardSpan = max(4, Int((Double(contentH) * 0.01).rounded()))
        var rival = 1e9
        for s in sMin...sMax where abs(s - bestS) > guardSpan {
            if scores[s] < rival { rival = scores[s] }
        }
        let ratio = (rival < 1e8 && best > 0) ? rival / best : Double.infinity
        let bestRows = rowsN[bestS]

        // 候选：得分接近最优的位移，合并相邻只留谷底
        let tol = best * 1.35 + 2
        var merged: [Int] = []
        for s in sMin...sMax where scores[s] <= tol {
            if let last = merged.last, s - last <= 2 {
                if scores[s] < scores[last] { merged[merged.count - 1] = s }
            } else {
                merged.append(s)
            }
        }
        let lo = Int((Double(contentH) * overlapTrustFrac).rounded())
        let hi = Int((Double(contentH) * overlapMaxFrac).rounded())
        let inRange = merged.filter { $0 >= lo && $0 <= hi }
        let pick = inRange.isEmpty ? merged : inRange

        // 置信：参与行数够 + 峰够突出（或落在可信区间且无强对手）
        let low = bestRows < minRows
            || pick.isEmpty
            || !(ratio >= 1.45 || (bestS >= lo && bestS <= hi && ratio >= 1.2))
        let dup = bestS >= sMax - 2 && ratio < 1.3

        return ShiftResult(s: bestS, score: best, low: low, duplicate: dup,
                           candidates: pick, flat: false, contrast: ratio, rows: bestRows)
    }

    static func hasTexture(_ p: RowPrint, minRows: Int) -> Bool {
        var cnt = 0
        for y in 0..<p.height {
            if p.rowTexture(y) > RowPrint.textureMin {
                cnt += 1
                if cnt >= minRows { return true }
            }
        }
        return false
    }

    // MARK: - 估算固定栏（多对取中位数）

    static func estimateChrome(_ items: [Input], sensitivity: Int) -> (topSrc: Double, botSrc: Double) {
        guard items.count >= 2 else { return (0, 0) }
        var tops: [Double] = [], bots: [Double] = []
        for i in 1..<items.count {
            let cur = items[i]
            let r = detectChrome(items[i - 1].chromePrint, cur.chromePrint, sensitivity: sensitivity)
            // 换算到「后一张」的源图像素，统一量纲后再取中位数
            let k = cur.k > 0 ? cur.k : 1
            tops.append(Double(r.top) / k)
            bots.append(Double(r.bot) / k)
        }
        return (median(tops), median(bots))
    }

    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[s.count / 2]
    }

    // MARK: - 主流程

    /// 计算整批截图的拼接方案。
    ///
    /// - Parameters:
    ///   - images: 按顺序排好的截图
    ///   - sensitivity: 匹配灵敏度 1...5
    ///   - detectChromeEnabled: 是否自动去除固定栏
    ///   - trimTrailing: 是否裁掉末张尾部留白
    ///   - useSmartMatch: 是否做智能重叠识别
    static func makePlan(images: [CGImage],
                         sensitivity: Int = 3,
                         detectChromeEnabled: Bool = true,
                         trimTrailing: Bool = true,
                         useSmartMatch: Bool = true) -> Plan? {
        let inputs = images.compactMap(prepare)
        guard !inputs.isEmpty else { return nil }
        var outputs = [Output](repeating: Output(), count: inputs.count)
        let n = inputs.count

        guard n >= 2 else {
            for i in 0..<n {
                outputs[i].keepStart = 0
                outputs[i].keepEnd = inputs[i].height
            }
            return Plan(outputs: outputs, totalHeight: inputs[0].height,
                        stepMedian: inputs[0].height, lowCount: 0, dupCount: 0)
        }

        // ---- 1) 顶部/底部固定栏：逐对探测后取中位数，抗单对误判 ----
        let chrome = estimateChrome(inputs, sensitivity: sensitivity)
        for i in 0..<n {
            let it = inputs[i]
            let cap = Int(Double(it.height) * 0.14)   // 上限 14%，避免误吞正文
            outputs[i].c = detectChromeEnabled
                ? max(0, min(cap, Int(chrome.topSrc.rounded())))
                : 0
            outputs[i].d = detectChromeEnabled
                ? max(0, min(cap, Int(chrome.botSrc.rounded())))
                : 0
        }

        // ---- 2) 逐对求重叠位移 ----
        struct Pair {
            let index: Int
            let result: ShiftResult
            let contentH: Int
            var chosen: Int
            var impliedStep: Double
            var forced: Bool = false
        }
        var pairs: [Pair] = []

        for i in 1..<n {
            let prev = inputs[i - 1], cur = inputs[i]
            if !useSmartMatch {
                outputs[i].s = 0
                outputs[i].lowConfidence = true
                continue
            }
            let cA = Int((Double(outputs[i - 1].c) * prev.k).rounded())
            let dA = Int((Double(outputs[i - 1].d) * prev.k).rounded())
            let cB = Int((Double(outputs[i].c) * cur.k).rounded())

            let r = findShift(prev, cur, cA: cA, dA: dA, cB: cB, sensitivity: sensitivity)
            let contentH = min(prev.print.height - cA - dA, cur.print.height - cB)
            let step = (Double(contentH) - Double(r.s)) / (cur.k > 0 ? cur.k : 1)
            pairs.append(Pair(index: i, result: r, contentH: contentH,
                              chosen: r.s, impliedStep: step))
        }

        // ---- 3) 消歧：人工滚屏时每屏步长基本恒定 ----
        if !pairs.isEmpty {
            let steps = pairs.map { $0.impliedStep }
            var stepMedian = median(steps)
            if pairs.count >= 3 {
                let good = steps.filter { abs($0 - stepMedian) <= stepMedian * 0.30 }
                if good.count >= 2 { stepMedian = median(good) }
            }

            // 候选里挑最贴近共识步长的
            for idx in pairs.indices {
                let p = pairs[idx]
                guard p.result.candidates.count > 1 else {
                    pairs[idx].chosen = p.result.candidates.first ?? p.result.s
                    continue
                }
                let k = inputs[p.index].k > 0 ? inputs[p.index].k : 1
                var bestD = Double.infinity
                var pick = p.result.candidates[0]
                for c in p.result.candidates {
                    let st = (Double(p.contentH) - Double(c)) / k
                    let dd = abs(st - stepMedian)
                    if dd < bestD { bestD = dd; pick = c }
                }
                pairs[idx].chosen = pick
                pairs[idx].impliedStep = (Double(p.contentH) - Double(pick)) / k
            }

            // 偏离共识过多的对，用共识步长反推，保证接缝连续
            for idx in pairs.indices {
                let dev = abs(pairs[idx].impliedStep - stepMedian)
                let tol = max(6, stepMedian * 0.03)
                pairs[idx].forced = dev > tol
            }

            for p in pairs {
                let i = p.index
                let k = inputs[i].k > 0 ? inputs[i].k : 1
                if p.forced {
                    let keep = Double(inputs[i - 1].height - outputs[i - 1].d) - stepMedian
                    let sSrc = keep - Double(outputs[i].c)
                    outputs[i].s = max(0, min(inputs[i].height, Int(sSrc.rounded())))
                    outputs[i].lowConfidence = true
                } else {
                    let sSrc = Double(p.chosen) / k
                    outputs[i].s = max(0, min(inputs[i].height, Int(sSrc.rounded())))
                    let ambiguous = p.result.candidates.count > 3
                    outputs[i].lowConfidence = p.result.low || ambiguous || p.result.flat
                }
                outputs[i].duplicate = p.result.duplicate
            }

            // 只有一对（2 张图）时无法用共识纠错：明确标为需要手动确认
            if pairs.count == 1 && outputs[pairs[0].index].lowConfidence {
                // lowConfidence 已置位，调用方据此提示
            }

            // ---- 4) 汇总裁切窗口 ----
            var y = 0
            for i in 0..<n {
                let H = inputs[i].height
                let start = (i == 0) ? 0 : (outputs[i].c + outputs[i].s)
                var end = H - outputs[i].d
                if i == n - 1 && trimTrailing {
                    let t = trailingBlank(inputs[i], d: outputs[i].d)
                    if t > 0 { end = max(Int(Double(H) * 0.2), end - t) }
                }
                if end - start < 8 { end = min(H, start + 8) }
                outputs[i].keepStart = max(0, min(H - 1, start))
                outputs[i].keepEnd = max(outputs[i].keepStart + 1, min(H, end))

                let outH = outputs[i].keepEnd - outputs[i].keepStart
                // 软融合宽度随重叠量自适应
                if i == 0 {
                    outputs[i].feather = 0
                } else {
                    let auto = Int(Double(min(outputs[i].s, outH)) * 0.35)
                    let cap = Int(Double(H) * 0.06)
                    outputs[i].feather = max(0, min(cap, auto))
                }
                y += outH
            }

            let lowCount = outputs.filter { $0.lowConfidence }.count
            let dupCount = outputs.filter { $0.duplicate }.count
            return Plan(outputs: outputs, totalHeight: y,
                        stepMedian: Int(stepMedian.rounded()),
                        lowCount: lowCount, dupCount: dupCount)
        }

        // 没有可用的对（此分支只在全部 !useSmartMatch 时到达）
        var y = 0
        for i in 0..<n {
            outputs[i].keepStart = 0
            outputs[i].keepEnd = inputs[i].height
            y += inputs[i].height
        }
        return Plan(outputs: outputs, totalHeight: y, stepMedian: 0,
                    lowCount: outputs.filter { $0.lowConfidence }.count, dupCount: 0)
    }

    /// 尾部空白：自底部固定栏往上，连续纯色行数（返回源图像素）。
    ///
    /// 不比较相邻两行的差分 —— 固定栏边缘的抗锯齿经降采样后会向上扩散几行，
    /// 差分判据会在第一行就失败，导致永远裁不掉留白。
    static func trailingBlank(_ it: Input, d: Int) -> Int {
        let p = it.print
        let bottom = p.height - Int((Double(d) * it.k).rounded())
        guard bottom >= 8 else { return 0 }
        let maxScan = Int(Double(p.height) * 0.6)
        var cnt = 0
        var y = bottom - 1
        while y >= bottom - maxScan && y > 1 {
            if p.rowTexture(y) <= RowPrint.textureMin { cnt += 1 } else { break }
            y -= 1
        }
        let srcPx = Int((Double(cnt) / (it.k > 0 ? it.k : 1)).rounded())
        return srcPx >= 24 ? srcPx : 0
    }
}
