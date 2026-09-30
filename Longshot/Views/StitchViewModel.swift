import Foundation
import UIKit
import Photos
import SwiftUI
import Observation

/// 主流程状态机。
@Observable
@MainActor
final class StitchViewModel {

    enum Stage: Equatable {
        case empty
        case ready
        case working(String, Double)
        case done
        case failed(String)
    }

    var items: [ShotItem] = []
    var stage: Stage = .empty
    var resultImage: UIImage?
    /// 左右裁切（裁掉量），对所有截图统一生效
    var cropLeft: Int = 0
    var cropRight: Int = 0

    // 设置项，持久化到 UserDefaults
    var sensitivity: Int = 3 { didSet { save() } }
    var autoChrome: Bool = true { didSet { save() } }
    var trimTrailing: Bool = true { didSet { save() } }
    var smartMatch: Bool = true { didSet { save() } }
    var featherEnabled: Bool = true { didSet { save() } }
    var quality: Double = 1.0 { didSet { save() } }
    var horizontal: Bool = false { didSet { save() } }

    private var plan: LongshotEngine.Plan?
    private var preparedCache: [UUID: LongshotEngine.Input] = [:]

    private let settingsKey = "longshot.settings.v1"

    init() { load() }

    // MARK: - 增删

    func add(_ new: [ShotItem]) {
        items.append(contentsOf: new)
        // 按文件名里的数字自然排序，符合连拍截图的命名规律
        items.sort { naturalLess($0.displayName, $1.displayName) }
        invalidate()
        recalc()
    }

    func remove(at offsets: IndexSet) {
        items.remove(atOffsets: offsets)
        invalidate()
        recalc()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        invalidate()
        recalc()
    }

    func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        invalidate()
        recalc()
    }

    func clear() {
        items = []
        plan = nil
        resultImage = nil
        preparedCache.removeAll()
        stage = .empty
    }

    private func invalidate() {
        plan = nil
        resultImage = nil
        preparedCache.removeAll()
    }

    // MARK: - 计算

    /// 重新跑一遍引擎，把结果写回每张图的展示字段。
    func recalc() {
        guard items.count >= 2 else {
            for it in items {
                it.keepStart = it.manualKeep?.start ?? 0
                it.keepEnd = it.manualKeep?.end ?? it.pixelHeight
                it.c = 0; it.d = 0; it.s = 0; it.feather = 0
                it.lowConfidence = false; it.duplicate = false
            }
            stage = items.isEmpty ? .empty : .ready
            return
        }

        stage = .working("正在分析重叠", 0.2)

        let images = items.compactMap { $0.source }
        guard images.count == items.count else {
            stage = .failed("有图片尚未加载完成")
            return
        }

        guard let p = LongshotEngine.makePlan(
            images: images,
            sensitivity: sensitivity,
            detectChromeEnabled: autoChrome,
            trimTrailing: trimTrailing,
            useSmartMatch: smartMatch
        ) else {
            stage = .failed("分析失败，请重试")
            return
        }

        plan = p
        for (i, it) in items.enumerated() where i < p.outputs.count {
            let o = p.outputs[i]
            it.c = o.c; it.d = o.d; it.s = o.s
            it.feather = featherEnabled ? o.feather : 0
            it.lowConfidence = o.lowConfidence
            it.duplicate = o.duplicate
            if let m = it.manualKeep {
                it.keepStart = m.start
                it.keepEnd = m.end
            } else {
                it.keepStart = o.keepStart
                it.keepEnd = o.keepEnd
            }
        }
        stage = .ready
    }

    /// 用户手动校准某一张。
    func applyManual(index: Int, start: Int, end: Int, newS: Int?) {
        guard items.indices.contains(index) else { return }
        let it = items[index]
        let s = max(0, min(it.pixelHeight, start))
        let e = max(s + 2, min(it.pixelHeight, end))
        it.manualKeep = (s, e)
        it.keepStart = s
        it.keepEnd = e
        it.lowConfidence = false
        if let ns = newS { it.s = max(0, min(it.pixelHeight, ns)) }
        // 只重算输出高度，不重跑对齐
        refreshPlanWindows()
    }

    func resetManual(index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].manualKeep = nil
        recalc()
    }

    private func refreshPlanWindows() {
        var total = 0
        for it in items {
            it.feather = featherEnabled
                ? max(0, min(Int(Double(it.pixelHeight) * 0.06),
                             Int(Double(min(it.s, it.keptHeight)) * 0.35)))
                : 0
            total += it.keptHeight
        }
        if var p = plan {
            p.totalHeight = total
            p.lowCount = items.filter { $0.lowConfidence }.count
            p.dupCount = items.filter { $0.duplicate }.count
            plan = p
        } else if items.count >= 2 {
            recalc()
        }
    }

    var estimatedHeight: Int {
        plan?.totalHeight ?? items.reduce(0) { $0 + $1.keptHeight }
    }

    var outputWidth: Int {
        let base = items.map { $0.pixelWidth }.max() ?? 0
        let l = min(cropLeft, max(0, base - 8))
        let r = min(cropRight, max(0, base - l - 8))
        return max(0, Int(Double(base - l - r) * quality))
    }

    // MARK: - 拼接

    func stitch() async {
        guard items.count >= 2 else {
            stage = .failed("至少需要 2 张截图")
            return
        }
        // 保证 plan 与当前参数一致
        if plan == nil { recalc() }
        guard let p = plan else { return }

        stage = .working("正在拼接", 0.5)
        await Task.yield()

        let images = items.compactMap { $0.source }
        // 把每张的手动裁切写回 plan
        var merged = p
        for (i, it) in items.enumerated() where i < merged.outputs.count {
            merged.outputs[i].keepStart = it.keepStart
            merged.outputs[i].keepEnd = it.keepEnd
            merged.outputs[i].feather = it.feather
        }

        let base = items.map { $0.pixelWidth }.max() ?? 0
        let l = min(cropLeft, max(0, base - 8))
        let r = min(cropRight, max(0, base - l - 8))

        guard let r2 = Stitcher.render(images: images, plan: merged,
                                       cropLeft: l, cropRight: r,
                                       quality: quality,
                                       horizontal: horizontal),
              let ui = UIImage(cgImage: r2.image) as UIImage?
        else {
            stage = .failed("拼接失败，可能是图片过大导致内存不足")
            return
        }

        stage = .working("正在导出图片", 0.8)
        await Task.yield()

        resultImage = ui
        stage = .done
    }

    // MARK: - 保存 / 分享

    /// 保存到相册（只请求「添加」权限，不读取相册）。
    func saveToPhotos() async -> Result<Void, Error> {
        guard let img = resultImage else {
            return .failure(StitchError.noResult)
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            return .failure(StitchError.noPermission)
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo,
                                                              data: img.pngData() ?? Data(),
                                                              options: nil)
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func shareFileURL() -> URL? {
        guard let data = resultImage?.pngData() else { return nil }
        let name = "长截图_\(Self.timestamp()).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return url
        } catch { return nil }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    // MARK: - 设置持久化

    private func save() {
        let d = UserDefaults.standard
        d.set(sensitivity, forKey: settingsKey + ".sensitivity")
        d.set(autoChrome, forKey: settingsKey + ".autoChrome")
        d.set(trimTrailing, forKey: settingsKey + ".trimTrailing")
        d.set(smartMatch, forKey: settingsKey + ".smartMatch")
        d.set(featherEnabled, forKey: settingsKey + ".feather")
        d.set(quality, forKey: settingsKey + ".quality")
        d.set(horizontal, forKey: settingsKey + ".horizontal")
        d.set(cropLeft, forKey: settingsKey + ".cropLeft")
        d.set(cropRight, forKey: settingsKey + ".cropRight")
    }

    private func load() {
        let d = UserDefaults.standard
        func has(_ k: String) -> Bool { d.object(forKey: settingsKey + "." + k) != nil }
        if has("sensitivity") { sensitivity = d.integer(forKey: settingsKey + ".sensitivity") }
        if has("autoChrome") { autoChrome = d.bool(forKey: settingsKey + ".autoChrome") }
        if has("trimTrailing") { trimTrailing = d.bool(forKey: settingsKey + ".trimTrailing") }
        if has("smartMatch") { smartMatch = d.bool(forKey: settingsKey + ".smartMatch") }
        if has("feather") { featherEnabled = d.bool(forKey: settingsKey + ".feather") }
        if has("quality") { quality = d.double(forKey: settingsKey + ".quality") }
        if has("horizontal") { horizontal = d.bool(forKey: settingsKey + ".horizontal") }
        if has("cropLeft") { cropLeft = d.integer(forKey: settingsKey + ".cropLeft") }
        if has("cropRight") { cropRight = d.integer(forKey: settingsKey + ".cropRight") }
    }
}

enum StitchError: LocalizedError {
    case noResult
    case noPermission

    var errorDescription: String? {
        switch self {
        case .noResult: return "还没有生成结果"
        case .noPermission: return "没有相册写入权限，请在「设置」里允许"
        }
    }
}

/// 自然排序：把字符串里的连续数字当数值比较。
///
/// 截图文件名通常是「截图 2.png」「截图 10.png」这种形式，
/// 按字典序排会得到 1、10、2、3…… 的顺序，与用户预期不符。
/// 这里不依赖 localizedStandardCompare（它受当前区域设置影响，
/// 在部分语言下行为不一致），自己按字符扫描更可控。
func naturalLess(_ a: String, _ b: String) -> Bool {
    let x = Array(a), y = Array(b)
    var i = 0, j = 0
    while i < x.count && j < y.count {
        let cx = x[i], cy = y[j]
        if cx.isNumber && cy.isNumber {
            // 各自取出一段完整数字
            var ni = i, nj = j
            while ni < x.count, x[ni].isNumber { ni += 1 }
            while nj < y.count, y[nj].isNumber { nj += 1 }
            let sx = String(x[i..<ni]), sy = String(y[j..<nj])
            // 先比数值，数值相同再比位数（处理 01 与 1）
            let vx = Int(sx) ?? 0, vy = Int(sy) ?? 0
            if vx != vy { return vx < vy }
            if sx.count != sy.count { return sx.count < sy.count }
            i = ni; j = nj
            continue
        }
        if cx != cy { return cx < cy }
        i += 1; j += 1
    }
    return x.count < y.count
}
