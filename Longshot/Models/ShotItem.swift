import Foundation
import UIKit
import Photos
import CoreGraphics

/// 一张待拼接的截图。
@Observable
final class ShotItem: Identifiable {
    let id = UUID()
    /// 展示用缩略图（列表里的小图）
    var thumbnail: UIImage?
    /// 分析 + 渲染用的位图
    var source: CGImage?
    /// 原始像素尺寸
    var pixelWidth = 0
    var pixelHeight = 0
    /// 文件名或相册序号，仅用于展示
    var displayName: String = ""
    /// 用户手动校准过的裁切（非 nil 表示不再自动覆盖）
    var manualKeep: (start: Int, end: Int)?
    /// 引擎结果快照，供列表展示
    var c = 0
    var d = 0
    var s = 0
    var keepStart = 0
    var keepEnd = 0
    var feather = 0
    var lowConfidence = false
    var duplicate = false

    init(image: UIImage?, name: String) {
        self.displayName = name
        guard let image else { return }
        // 统一把方向烤进像素，后续算法不必再考虑 EXIF
        let normalized = image.normalizedUp()
        self.thumbnail = normalized.preparingThumbnail(of: CGSize(width: 120, height: 240))
            ?? normalized
        self.source = normalized.cgImage
        self.pixelWidth = normalized.cgImage?.width ?? 0
        self.pixelHeight = normalized.cgImage?.height ?? 0
        if self.pixelWidth > 0 {
            self.keepStart = 0
            self.keepEnd = self.pixelHeight
        }
    }

    var keptRatio: Int {
        guard pixelHeight > 0 else { return 100 }
        return Int((Double(keepEnd - keepStart) / Double(pixelHeight) * 100).rounded())
    }

    var keptHeight: Int { max(0, keepEnd - keepStart) }

    var statusText: String {
        if duplicate { return "重复" }
        if lowConfidence { return "待确认" }
        return "跳过 \(keepStart)"
    }

    var statusLevel: Int {
        if duplicate { return 2 }
        if lowConfidence { return 1 }
        return 0
    }
}

extension UIImage {
    /// 把 imageOrientation 烘焙进像素，返回 .up 的图。
    ///
    /// iPhone 截图通常已经是 .up，但相机照片可能是 .right 等，
    /// 若不统一，后续的裁切坐标会整体错位。
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 缩放到最长边不超过 maxDimension。
    /// 超过时按比例缩小，避免占用过多内存。
    func limited(maxDimension: Int) -> UIImage {
        let m = max(size.width, size.height)
        guard m > CGFloat(maxDimension), m > 0 else { return self }
        let k = CGFloat(maxDimension) / m
        let target = CGSize(width: max(1, size.width * k), height: max(1, size.height * k))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

/// 从相册 / 文件读取图片。
enum ImageLoader {

    /// 供外部直接传 UIImage（分享扩展、拖放等）
    static func make(from images: [UIImage]) -> [ShotItem] {
        images.enumerated().map { ShotItem(image: $1, name: "截图 \($0 + 1)") }
    }

    /// 读取 PHAsset（分享扩展 / 直接相册访问用）
    ///
    /// 用 withCheckedThrowingContinuation 而不是非 throwing 版本：
    /// PHImageManager 可能在同一个请求里回调多次（先给低清预览再给高清），
    /// 这里用 finished 标志保证只 resume 一次。
    static func load(asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { cont in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.version = .current
            var resumed = false
            PHImageManager.default().requestImage(for: asset,
                                                 targetSize: targetSize,
                                                 contentMode: .aspectFit,
                                                 options: options) { img, info in
                // 高清结果才算完成； degraded 的中间结果直接忽略
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: img)
            }
        }
    }
}
