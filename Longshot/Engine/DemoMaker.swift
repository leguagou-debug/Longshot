import Foundation
import UIKit
import CoreGraphics

/// 生成「滚屏截图」示例，用于在没有真实截图时体验与自检。
///
/// 建模与真实 iOS 一致：
/// 固定状态栏（含灵动岛）+ 可滚动内容区 + 固定底部标签栏，
/// 相邻两屏滚动步长小于内容区高度，因而天然存在重叠。
enum DemoMaker {

    static let width = 1170
    static let viewportHeight = 2532
    static let topBar = 140
    static let bottomBar = 150
    /// 内容区可视高度
    static var contentVisibleHeight: Int { viewportHeight - topBar - bottomBar }

    /// 期望的重叠量，供自检使用
    struct Expectation {
        let step: Int
        let overlap: Int
        let top: Int
        let bottom: Int
        let viewportHeight: Int
    }

    /// 生成 4 张示例截图 + 期望值。
    /// 正文内容刻意做到「段落各异」—— 若反复填同一段文字，
    /// 内容会呈现强周期性，屏间位移附近会出现多个近乎等价的匹配点，
    /// 重叠识别必然歧义（真实长文不会这样）。
    static func makeDemo(count: Int = 4) -> ([UIImage], Expectation) {
        let w = width, vh = viewportHeight
        let cvh = contentVisibleHeight
        let step = Int((Double(cvh) * 0.55).rounded())   // 重叠 45%
        let overlap = cvh - step
        let contentH = (count - 1) * step + Int(Double(cvh) * 0.78)

        let doc = makeDocument(width: w, height: contentH)

        var shots: [UIImage] = []
        for i in 0..<count {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            // 全程不手动翻转：UIGraphicsImageRenderer 的上下文原点已在左上、
            // y 向下，draw(image:in:) 会自行把 CGImage 正着画出来。
            // 之前这里是「渲染器已翻转 + 代码再翻一次」，状态栏被画到屏幕底部、
            // 内容落点整体偏移，引擎因此找不到正确重叠（实测步长 2236 ≈ 内容全高）。
            let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: vh),
                                             format: format).image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor.white.cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(vh)))

                // 内容区 = 视觉行 topBar .. topBar + sh；文档第 i*step 行对齐到 topBar。
                // cropping 的 y 是「文档自顶向下」的坐标，与 CGImage 的行序一致。
                let sy = i * step
                let sh = min(cvh, max(0, contentH - sy))
                if sh > 0, let sub = doc?.cropping(to: CGRect(x: 0, y: sy,
                                                             width: w, height: sh)) {
                    cg.draw(sub, in: CGRect(x: 0, y: CGFloat(topBar),
                                            width: CGFloat(w), height: CGFloat(sh)))
                }

                paintTopBar(cg, w: w)
                paintBottomBar(cg, w: w, vh: vh)
            }
            shots.append(img)
        }
        return (shots, Expectation(step: step, overlap: overlap,
                                   top: topBar, bottom: bottomBar,
                                   viewportHeight: vh))
    }

    // MARK: - 文档内容

    /// 画一段连续长文档。每段取不同句子，避免周期性。
    ///
    /// 单元测试要用同一份文档做「真值」比对，所以这里不能是 private ——
    /// 测试若自己另画一份近似图案，逐像素比对就失去意义。
    static func makeDocument(width w: Int, height h: Int) -> CGImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h),
                                       format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setFillColor(UIColor.white.cgColor)
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))

            let headings = ["1. 设计原则", "2. 色彩系统", "3. 字体与排版", "4. 组件库",
                            "5. 交互与动效", "6. 无障碍", "7. 交付流程", "8. 版本记录",
                            "9. 图标规范", "10. 空状态设计", "11. 表单校验", "12. 多语言适配"]
            let paragraphs = [
                "界面应当保持克制，层级清晰，让用户一眼看出主次关系。",
                "所有组件默认遵循 8pt 栅格，间距取 8 的整数倍，避免出现奇数边距。",
                "主色仅用于关键操作，同屏出现的强调色不应超过两种，防止视觉噪声。",
                "正文与背景的对比度至少达到 4.5:1，大字号可放宽到 3:1。",
                "圆角在全平台保持统一，卡片 16pt，按钮 14pt，输入框 12pt。",
                "描边优先使用半透明黑，深浅模式下均取 0.5pt，避免发虚或过重。",
                "动效时长控制在 200 到 400 毫秒之间，缓动曲线统一使用标准减速曲线。",
                "列表项高度不小于 44pt，保证单手操作的点击热区足够宽裕。",
                "空状态需要同时给出原因和下一步操作，不能只放一句冰冷提示。",
                "表单错误信息紧贴对应字段显示，并在提交时自动滚动到第一个错误处。",
                "长文本截断优先使用尾部省略，同时保留完整内容供辅助技术读取。",
                "横屏与分屏场景下需要重新评估信息密度，必要时折叠次要操作。",
                "深浅两套主题共用同一套语义色板，禁止在业务代码里写死色值。",
                "图标需提供 1x 与 2x 两套切图，线宽与图形本体保持视觉等重。",
                "交互动效不得阻塞主线程，超过 100 毫秒的运算一律放到后台线程。",
                "多语言场景预留 30% 的文案膨胀空间，避免出现挤压或换行错位。"
            ]

            // 不手动翻转：渲染器上下文已是左上原点、y 向下。
            // 文字统一走 UIKit 的绘制 API（坐标系同样是左上原点），
            // 避免与 CoreText / CTM 叠加后方向说不清而整体画反。
            var y = 110
            drawText("产品设计规范 v2.4", at: CGPoint(x: 72, y: y),
                     font: .systemFont(ofSize: 66, weight: .semibold),
                     color: UIColor(red: 0, green: 0.478, blue: 1, alpha: 1))
            y += 110
            drawText("最后更新 2026-10-01 · 内部资料", at: CGPoint(x: 72, y: y),
                     font: .systemFont(ofSize: 34), color: .gray)
            y += 104

            var hi = 0, pi = 0
            while y < h - 240 {
                drawText(headings[hi % headings.count], at: CGPoint(x: 72, y: y),
                         font: .systemFont(ofSize: 50, weight: .semibold),
                         color: .black)
                y += 84
                hi += 1

                for _ in 0..<4 where y < h - 240 {
                    let text = paragraphs[pi % paragraphs.count]
                    pi += 1
                    drawWrapped(text, x: 72, y: y, maxWidth: CGFloat(w - 150),
                                font: .systemFont(ofSize: 36), color: UIColor(white: 0.24, alpha: 1))
                    y += 56
                }

                cg.setStrokeColor(UIColor(white: 0.9, alpha: 1).cgColor)
                cg.setLineWidth(2)
                cg.move(to: CGPoint(x: 72, y: y + 8))
                cg.addLine(to: CGPoint(x: w - 72, y: y + 8))
                cg.strokePath()
                y += 96
            }
        }.cgImage
    }

    /// 单行文本。左上原点，y 向下。
    private static func drawText(_ s: String, at p: CGPoint, font: UIFont,
                                 color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (s as NSString).draw(at: p, withAttributes: attrs)
    }

    /// 按宽度自动折行。左上原点，y 向下。
    private static func drawWrapped(_ s: String, x: Int, y: Int, maxWidth: CGFloat,
                                    font: UIFont, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = CGRect(x: CGFloat(x), y: CGFloat(y),
                          width: maxWidth, height: 200)
        (s as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                             attributes: attrs, context: nil)
    }

    // MARK: - 固定栏

    /// 状态栏：时钟在左、电量在右，中部有灵动岛。
    /// 灵动岛很关键 —— 它让中段检测带有真正的内容，
    /// 也是固定状态栏能被识别出来的依据。
    static func paintTopBar(_ cg: CGContext, w: Int) {
        // UIGraphicsImageRenderer 的上下文原点已经是左上、y 向下，
        // 这里不要再翻转一次 —— 多翻一次会把状态栏画到屏幕底部。
        cg.setFillColor(UIColor(white: 0.969, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(topBar)))

        cg.setFillColor(UIColor.black.cgColor)
        // 灵动岛
        let island = CGRect(x: CGFloat(w) / 2 - 70, y: 22, width: 140, height: 34)
        cg.addPath(CGPath(roundedRect: island, cornerWidth: 17, cornerHeight: 17, transform: nil))
        cg.fillPath()
        // 时钟 / 电量
        let clock = CGRect(x: 90, y: 62, width: 150, height: 34)
        cg.addPath(CGPath(roundedRect: clock, cornerWidth: 6, cornerHeight: 6, transform: nil))
        cg.fillPath()
        let battery = CGRect(x: CGFloat(w) - 240, y: 62, width: 150, height: 34)
        cg.addPath(CGPath(roundedRect: battery, cornerWidth: 6, cornerHeight: 6, transform: nil))
        cg.fillPath()
    }

    /// 底部标签栏：顶部分隔线 + 中部选中图标 + home 指示条。
    /// 中部图标同样重要 —— 它让固定栏在检测带内有内容可比。
    static func paintBottomBar(_ cg: CGContext, w: Int, vh: Int) {
        // 同上：不要再翻转。左上原点、y 向下，底栏就在 vh-bottomBar .. vh。
        let y0 = CGFloat(vh - bottomBar)
        cg.setFillColor(UIColor(white: 0.98, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: y0, width: CGFloat(w), height: CGFloat(bottomBar)))
        // 分隔线
        cg.setFillColor(UIColor(white: 0.88, alpha: 1).cgColor)
        cg.fill(CGRect(x: 0, y: y0, width: CGFloat(w), height: 3))
        // 中部选中图标（在 0.22~0.78 检测带内）
        cg.setFillColor(UIColor.black.cgColor)
        // 注意：x 用 Double、y 用 Int（y0 + 55）会同时不匹配 CGRect 的
        // Double 重载与 Int 重载，直接编译报错。统一显式写成 CGFloat。
        let midIcon = CGRect(x: CGFloat(w) / 2 - 52, y: y0 + 55,
                             width: 104, height: 60)
        cg.addPath(CGPath(roundedRect: midIcon, cornerWidth: 14, cornerHeight: 14, transform: nil))
        cg.fillPath()
        // 左侧项
        cg.setFillColor(UIColor(white: 0.55, alpha: 1).cgColor)
        let leftItem = CGRect(x: CGFloat(w) * 0.30 - 40, y: y0 + 60,
                              width: 80, height: 50)
        cg.addPath(CGPath(roundedRect: leftItem, cornerWidth: 12, cornerHeight: 12, transform: nil))
        cg.fillPath()
        // home 指示条
        cg.setFillColor(UIColor(white: 0.16, alpha: 1).cgColor)
        let homeBar = CGRect(x: CGFloat(w) / 2 - 160, y: CGFloat(vh) - 26,
                             width: 320, height: 10)
        cg.addPath(CGPath(roundedRect: homeBar, cornerWidth: 5, cornerHeight: 5, transform: nil))
        cg.fillPath()
    }
}

extension ShotItem {
    /// 生成一组示例截图，便于体验与自检。
    static func makeDemo() -> [ShotItem] {
        let (images, _) = DemoMaker.makeDemo()
        return images.enumerated().map { ShotItem(image: $1, name: "示例截图_\($0 + 1).png") }
    }
}
