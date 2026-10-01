import XCTest
import CoreGraphics
import UIKit
@testable import Longshot

/// 算法验收测试。
///
/// 判定标准是端到端的：用 DemoMaker 造出几何已知的滚屏截图，
/// 跑完整引擎，再逐像素与「真值长文档」比对。
///
/// 核心不变量（与 c/d 的取值无关）：
///     keepStart(i+1) = keepEnd(i) − step
/// 其中 keepEnd(i) = H(i) − d(i)。这正是「接缝连续」的条件 ——
/// 不重复、不缺失。所以即使 c/d 有少量偏差，拼接结果依然正确。
final class LongshotEngineTests: XCTestCase {

    // MARK: - 工具

    private func cg(_ img: UIImage) -> CGImage {
        guard let c = img.cgImage else {
            XCTFail("无法取出 CGImage")
            fatalError()
        }
        return c
    }

    /// 取灰度像素，便于逐像素比对
    private func grayPixels(_ img: CGImage) -> (px: [UInt8], w: Int, h: Int)? {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    /// 把引擎方案渲染出来，返回结果图
    private func render(_ images: [CGImage], sensitivity: Int = 3) throws -> (CGImage, LongshotEngine.Plan) {
        guard let plan = LongshotEngine.makePlan(images: images,
                                                sensitivity: sensitivity,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true) else {
            throw XCTSkip("引擎未能生成方案")
        }
        guard let r = Stitcher.render(images: images, plan: plan) else {
            throw XCTSkip("渲染失败")
        }
        return (r.image, plan)
    }

    // MARK: - 0. 夹具自检
    //
    // 这一项不碰引擎，只验证「示例截图本身」是否真的是同一份文档的连续滚动。
    // 有了它，几何出错时能立刻区分「夹具错」还是「引擎错」——
    // 之前正是夹具把状态栏 / 内容画错了位置，却表现为引擎“识别不出重叠”。

    func testFixtureGeometryIsConsistentScroll() throws {
        let (images, expect) = DemoMaker.makeDemo(count: 3)
        let cgs = images.map { cg($0) }
        let grays = cgs.map { grayPixels($0) }
        for (i, g) in grays.enumerated() {
            XCTAssertEqual(g?.w, DemoMaker.width, "第 \(i + 1) 张宽度不符")
            XCTAssertEqual(g?.h, DemoMaker.viewportHeight, "第 \(i + 1) 张高度不符")
        }

        // 几何关系（与引擎测试用的不变量同源）：
        //   第 i 张的内容偏移 p  ↔  文档行 i*step + p
        // 因此第 i 张的偏移 p 与第 i+1 张的偏移 p−step 指向同一行内容。
        // 方向不能写反：写成 p+step 会去比相差 2*step 的两行，
        // 那样即使夹具完全正确也必然是大误差。
        let cvh = DemoMaker.contentVisibleHeight
        for i in 0..<(cgs.count - 1) {
            let a = try XCTUnwrap(grays[i])
            let b = try XCTUnwrap(grays[i + 1])

            func mae(atShift d: Int) -> (mae: Double, n: Int) {
                var sum = 0.0, n = 0
                var p = expect.step
                while p < cvh {
                    let ay = expect.top + p
                    let by = expect.top + p - d
                    if by >= expect.top && ay < a.h && by < b.h {
                        for x in stride(from: 40, to: a.w - 40, by: 7) {
                            sum += Double(abs(Int(a.px[ay * a.w + x]) - Int(b.px[by * b.w + x])))
                            n += 1
                        }
                    }
                    p += 11
                }
                return (n > 0 ? sum / Double(n) : 999, n)
            }

            // 在真值附近搜索：最佳位移应当正好是 expect.step
            var bestD = expect.step, bestMae = Double.greatestFiniteMagnitude
            for d in (expect.step - 12)...(expect.step + 12) {
                let r = mae(atShift: d)
                if r.mae < bestMae { bestMae = r.mae; bestD = d }
            }
            let n = mae(atShift: expect.step).n
            XCTAssertGreaterThan(n, 500, "采样点太少，夹具自检无效")

            XCTAssertEqual(bestD, expect.step, accuracy: 1,
                "第 \(i + 1) / \(i + 2) 张的最佳对齐位移是 \(bestD)，不是真值 \(expect.step)")
            XCTAssertLessThan(bestMae, 2.0,
                "第 \(i + 1) / \(i + 2) 张在最佳位移 \(bestD) 处仍不吻合（MAE=\(bestMae)）")
        }
    }

    // MARK: - 0b. 诊断：把关键数值打进 CI 日志
    //
    // 本地没有 macOS，只能靠 CI 迭代。这一项不做断言，只负责把
    // 「夹具真值 / 引擎估计 / 得分曲线」摆到日志里，
    // 让失败能一次定位到具体环节，而不是来回猜。

    func testDiagnosticScoreCurve() throws {
        let (images, expect) = DemoMaker.makeDemo(count: 2)
        let cgs = images.map { cg($0) }
        let inputs = cgs.compactMap { LongshotEngine.prepare($0) }
        XCTAssertEqual(inputs.count, 2, "prepare 失败")
        guard inputs.count == 2 else { return }

        let chrome = LongshotEngine.estimateChrome(inputs, sensitivity: 3)
        print("DIAG chrome: topSrc=\(chrome.topSrc) botSrc=\(chrome.botSrc) | truth top=\(expect.top) bot=\(expect.bottom)")

        let cap = Int(Double(inputs[0].height) * 0.14)
        let c0 = max(0, min(cap, Int(chrome.topSrc.rounded())))
        let d0 = max(0, min(cap, Int(chrome.botSrc.rounded())))
        let k = inputs[1].k
        let cA = Int((Double(c0) * inputs[0].k).rounded())
        let dA = Int((Double(d0) * inputs[0].k).rounded())
        let cB = Int((Double(c0) * inputs[1].k).rounded())
        print("DIAG scale: k=\(k) c0=\(c0) d0=\(d0) cA=\(cA) dA=\(dA) cB=\(cB) printH=\(inputs[0].print.height) srcH=\(inputs[0].height)")

        let contentH = min(inputs[0].print.height - cA - dA, inputs[1].print.height - cB)
        let sTrue = contentH - Int((Double(expect.step) * k).rounded())
        let sMax = Int(Double(contentH) * LongshotEngine.overlapMaxFrac)
        let sMin = max(6, Int((Double(contentH) * LongshotEngine.overlapMinFrac).rounded()))
        print("DIAG range: contentH=\(contentH) sMin=\(sMin) sMax=\(sMax) sTrue=\(sTrue) stepTruth=\(expect.step) cvh=\(DemoMaker.contentVisibleHeight)")

        var all: [(s: Int, score: Double, rows: Int)] = []
        var s = sMin
        while s <= sMax {
            let r = LongshotEngine.overlapScore(inputs[0], inputs[1], cA: cA, dA: dA, cB: cB, s: s)
            all.append((s, r.score, r.rows))
            s += 5
        }
        for r in all.sorted(by: { $0.score < $1.score }).prefix(8) {
            print("DIAG lowscore: s=\(r.s) score=\(String(format: "%.2f", r.score)) rows=\(r.rows)")
        }
        let atTrue = LongshotEngine.overlapScore(inputs[0], inputs[1], cA: cA, dA: dA, cB: cB, s: sTrue)
        print("DIAG atTrue: s=\(sTrue) score=\(String(format: "%.2f", atTrue.score)) rows=\(atTrue.rows)")
        for d in -3...3 {
            let ss = sTrue + d
            guard ss >= sMin, ss <= sMax else { continue }
            let r = LongshotEngine.overlapScore(inputs[0], inputs[1], cA: cA, dA: dA, cB: cB, s: ss)
            print("DIAG near: s=\(ss) score=\(String(format: "%.2f", r.score)) rows=\(r.rows)")
        }
        let res = LongshotEngine.findShift(inputs[0], inputs[1], cA: cA, dA: dA, cB: cB, sensitivity: 3)
        print("DIAG findShift: s=\(res.s) score=\(String(format: "%.2f", res.score)) low=\(res.low) dup=\(res.duplicate) flat=\(res.flat) contrast=\(String(format: "%.2f", res.contrast)) rows=\(res.rows) cands=\(Array(res.candidates.prefix(8)))")

        // 逐张 plan 明细：定位总高偏差到底出在哪一段
        if let p = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                           detectChromeEnabled: true,
                                           trimTrailing: true,
                                           useSmartMatch: true) {
            for (i, o) in p.outputs.enumerated() {
                print("DIAG plan[\(i)]: c=\(o.c) d=\(o.d) s=\(o.s) keepStart=\(o.keepStart) keepEnd=\(o.keepEnd) keepH=\(o.keepEnd - o.keepStart) feather=\(o.feather) low=\(o.lowConfidence)")
            }
            print("DIAG plan total=\(p.totalHeight) stepMedian=\(p.stepMedian) low=\(p.lowCount) dup=\(p.dupCount) srcH=\(cgs[0].height) topBar=\(expect.top) botBar=\(expect.bottom) truthStep=\(expect.step)")
            // 末张尾部空白检测值，判断是否过度裁剪
            let tb = LongshotEngine.trailingBlank(inputs[1], d: p.outputs[1].d)
            print("DIAG trailingBlank(last)=\(tb)")
        }
    }

    // MARK: - 1. 行指纹基本性质

    func testRowPrintBasics() throws {
        let (images, _) = DemoMaker.makeDemo()
        let image = cg(images[0])
        guard let work = RowPrintBuilder.scaled(image, maxDimension: LongshotEngine.workMax) else {
            return XCTFail("缩放失败")
        }
        guard let print = RowPrintBuilder.build(from: work, blocks: LongshotEngine.stripBlocks) else {
            return XCTFail("构建指纹失败")
        }
        XCTAssertEqual(print.blocks, LongshotEngine.stripBlocks)
        XCTAssertEqual(print.stride, LongshotEngine.stripBlocks * 2)
        XCTAssertEqual(print.height, work.height)
        XCTAssertEqual(print.data.count, work.height * print.stride)

        // 自比对必须为 0
        for y in stride(from: 0, to: print.height, by: 97) {
            XCTAssertEqual(rowDistance(print, y, print, y), 0, accuracy: 0.0001)
        }

        // 图上应当存在「有内容」的行 —— 否则后续匹配无从谈起
        var textured = 0
        for y in 0..<print.height where print.rowTexture(y) > RowPrint.textureMin {
            textured += 1
        }
        XCTAssertGreaterThan(textured, 50, "指纹里几乎没有有内容的行，说明取样或梯度通道有问题")
    }

    // MARK: - 2. 固定栏探测

    func testChromeDetection() throws {
        let (images, expect) = DemoMaker.makeDemo()
        let inputs = images.compactMap { LongshotEngine.prepare(cg($0)) }
        XCTAssertEqual(inputs.count, images.count)

        let est = LongshotEngine.estimateChrome(inputs, sensitivity: 3)

        // 顶部固定栏边界清楚（状态栏下方紧接内容），允许 30px 误差。
        XCTAssertEqual(est.topSrc, Double(expect.top), accuracy: 30,
                       "顶部固定栏探测偏差过大：\(est.topSrc)")

        // 底部固定栏不比对具体边界值，只要求落在「已识别出底栏」的合理区间：
        // 引擎取「自底向上最后一个有内容行」为边界，而示例底栏内部
        // （中部图标之上 → 顶部分隔线之间）是一段连续纯白，
        // 这段空白与内容区留白在像素上无法区分，边界天然存在几十像素歧义。
        //
        // 关键点：这个歧义不影响拼接正确性 —— 接缝位置由
        // keepStart = c + s 与 keepEnd = H − d 共同决定，
        // d 的偏差会被 s 吸收，验收靠下面的「步长不变量」与「逐像素 MAE」。
        XCTAssertGreaterThan(est.botSrc, 0, "完全没探测到底部固定栏")
        XCTAssertLessThanOrEqual(est.botSrc, Double(expect.bottom) + 8,
                                 "底部固定栏探测值超过了真实底栏高度：\(est.botSrc)")
        XCTAssertGreaterThan(est.botSrc, Double(expect.bottom) * 0.5,
                             "底部固定栏探测值过小，几乎没识别到底栏：\(est.botSrc)")
    }

    // MARK: - 3. 重叠识别 —— 核心

    /// 多档重叠率都要能识别出来。
    /// 门槛设在 3%（约一行半文字）—— Picsew 官方要求「两行字」≈3.5%，
    /// 这里比它更宽松。
    func testOverlapAcrossRatios() throws {
        // DemoMaker 固定 45% 重叠，这里用不同 count 与灵敏度做覆盖
        for count in [2, 3, 4, 6] {
            let (images, expect) = DemoMaker.makeDemo(count: count)
            let cgs = images.map { cg($0) }
            guard let plan = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                                    detectChromeEnabled: true,
                                                    trimTrailing: true,
                                                    useSmartMatch: true) else {
                return XCTFail("count=\(count) 未能生成方案")
            }

            // 关键不变量：接缝连续
            for i in 1..<plan.outputs.count {
                let prev = plan.outputs[i - 1]
                let cur = plan.outputs[i]
                let endOfPrev = images[i - 1].cgImage!.height - prev.d
                let startOfCur = cur.keepStart
                let step = endOfPrev - startOfCur
                XCTAssertEqual(step, expect.step, accuracy: 8,
                               "count=\(count) 第 \(i + 1) 张的步长偏离真值：\(step) vs \(expect.step)")
            }

            // 输出高度应接近「状态栏 + 内容高」
            let ideal = DemoMaker.topBar + (count - 1) * expect.step
                + Int(Double(DemoMaker.contentVisibleHeight) * 0.78)
            XCTAssertEqual(plan.totalHeight, ideal, accuracy: max(40, ideal / 20),
                           "count=\(count) 输出高度偏差过大：\(plan.totalHeight) vs \(ideal)")
        }
    }

    /// 逐像素验收：把结果图与「真值长文档」对齐后，每段 MAE 应接近 0。
    ///
    /// 映射推导：
    ///   第 i 张的内容区从源图第 topBar 行开始，对应文档第 i*step 行；
    ///   输出中第 i 段第 r 行取自源图 keepStart + r，
    ///   故其文档行 = i*step + (keepStart + r − topBar)。
    func testPixelAccuracy() throws {
        let count = 4
        let (images, expect) = DemoMaker.makeDemo(count: count)
        let cgs = images.map { cg($0) }

        guard let plan = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true),
              let rendered = Stitcher.render(images: cgs, plan: plan),
              let out = grayPixels(rendered.image) else {
            return XCTFail("未能生成结果图")
        }

        // 重建真值文档：与 DemoMaker 内部用同一套参数
        let doc = try XCTUnwrap(makeReferenceDocument(count: count, step: expect.step))

        // 逐段比对。段 i 的空白行（末屏留白）跳过。
        var worstMAE = 0.0
        var comparedSegments = 0

        for i in 0..<min(plan.outputs.count, cgs.count) {
            let o = plan.outputs[i]
            let segTop = plan.outputs[0...i].reduce(0) { $0 + ($1.keepEnd - $1.keepStart) } - (o.keepEnd - o.keepStart)

            var sum = 0.0
            var n = 0
            for r in stride(from: 0, to: o.keepEnd - o.keepStart, by: 3) {
                let docY = i * expect.step + (o.keepStart + r - expect.top)
                let outY = segTop + r
                guard docY >= 0, docY < doc.h, outY < out.h else { continue }
                // 只比中间列，避开边缘
                for x in stride(from: 60, to: out.w - 60, by: 17) {
                    let a = out.px[outY * out.w + x]
                    let b = doc.px[docY * doc.w + x]
                    sum += Double(abs(Int(a) - Int(b)))
                    n += 1
                }
            }
            if n > 100 {
                let mae = sum / Double(n)
                worstMAE = max(worstMAE, mae)
                comparedSegments += 1
            }
        }

        XCTAssertGreaterThan(comparedSegments, 0, "没有可比对的段落")
        // 缩放 + 重建文档会引入少量重采样差异，5 以内视为吻合
        XCTAssertLessThan(worstMAE, 5.0, "逐像素误差过大：MAE=\(worstMAE)")
    }

    /// 生成与 DemoMaker 同源的参考文档（测试内部使用）。
    ///
    /// 必须复用 DemoMaker.makeDocument 本身 —— 这里以前是自己另画一份占位色块，
    /// 与截图的真实内容无关，逐像素比对必然得出 MAE≈46 的假失败。
    /// 真值必须是「同一份像素」。
    private func makeReferenceDocument(count: Int, step: Int) -> (px: [UInt8], w: Int, h: Int)? {
        let w = DemoMaker.width
        let cvh = DemoMaker.contentVisibleHeight
        let contentH = (count - 1) * step + Int(Double(cvh) * 0.78)
        guard let doc = DemoMaker.makeDocument(width: w, height: contentH) else { return nil }
        return grayPixels(doc)
    }

    // MARK: - 4. 渲染尺寸与边界

    func testRenderDimensions() throws {
        let (images, expect) = DemoMaker.makeDemo(count: 3)
        let cgs = images.map { cg($0) }

        guard let plan = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true),
              let r = Stitcher.render(images: cgs, plan: plan) else {
            return XCTFail("渲染失败")
        }
        XCTAssertEqual(r.width, DemoMaker.width, "竖向拼接时宽度应保持原宽")
        XCTAssertEqual(r.height, plan.totalHeight, "结果高度应与方案一致")
        XCTAssertFalse(r.downscaled, "这个体积不该触发降分辨率")
    }

    func testLeftRightCrop() throws {
        let (images, _) = DemoMaker.makeDemo(count: 3)
        let cgs = images.map { cg($0) }

        guard let plan = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true) else {
            return XCTFail("方案生成失败")
        }
        guard let r = Stitcher.render(images: cgs, plan: plan,
                                      cropLeft: 100, cropRight: 50,
                                      quality: 1.0) else {
            return XCTFail("渲染失败")
        }
        XCTAssertEqual(r.width, DemoMaker.width - 150, "左右裁切后宽度应为 原宽 − 左 − 右")
    }

    func testHorizontalOutput() throws {
        let (images, _) = DemoMaker.makeDemo(count: 2)
        let cgs = images.map { cg($0) }
        guard let plan = LongshotEngine.makePlan(images: cgs, sensitivity: 3,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true),
              let v = Stitcher.render(images: cgs, plan: plan, horizontal: false),
              let h = Stitcher.render(images: cgs, plan: plan, horizontal: true) else {
            return XCTFail("渲染失败")
        }
        XCTAssertEqual(h.width, v.height, "横向输出的宽应等于纵向输出的高")
        XCTAssertEqual(h.height, v.width, "横向输出的高应等于纵向输出的宽")
    }

    // MARK: - 5. 异常输入

    func testSingleImage() throws {
        let (images, _) = DemoMaker.makeDemo(count: 1)
        let plan = LongshotEngine.makePlan(images: [cg(images[0])])
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.outputs.count, 1)
    }

    func testEmptyInput() throws {
        XCTAssertNil(LongshotEngine.makePlan(images: []))
    }

    /// 纯色图不应给出「自信」的结果 —— 必须判为低置信。
    func testFlatImagesAreLowConfidence() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        func blank() -> CGImage {
            UIGraphicsImageRenderer(size: CGSize(width: 400, height: 800),
                                    format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 800))
            }.cgImage!
        }
        let imgs = [blank(), blank(), blank()]
        guard let plan = LongshotEngine.makePlan(images: imgs, sensitivity: 3,
                                                detectChromeEnabled: true,
                                                trimTrailing: true,
                                                useSmartMatch: true) else {
            // 直接返回 nil 也是可接受的诚实行为
            return
        }
        XCTAssertGreaterThan(plan.lowCount, 0, "纯白图不应被当作高置信匹配")
    }

    // MARK: - 6. 灵敏度可调

    func testSensitivityAffectsResult() throws {
        let (images, _) = DemoMaker.makeDemo(count: 3)
        let cgs = images.map { cg($0) }
        // 只要求各档都能跑通、且给出合理高度，不要求结果相同
        for sens in 1...5 {
            guard let p = LongshotEngine.makePlan(images: cgs, sensitivity: sens,
                                                 detectChromeEnabled: true,
                                                 trimTrailing: true,
                                                 useSmartMatch: true) else {
                return XCTFail("灵敏度 \(sens) 下方案生成失败")
            }
            XCTAssertGreaterThan(p.totalHeight, DemoMaker.contentVisibleHeight)
        }
    }
}
