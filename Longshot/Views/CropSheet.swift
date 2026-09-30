import SwiftUI

/// 裁切 / 重叠校准。
///
/// 提供两组控制：
/// - 上下裁切：每张各自，决定保留起点与终点
/// - 左右裁切：全局统一，用于去掉两侧黑边或留白
struct CropSheet: View {
    @Environment(StitchViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let index: Int

    @State private var start: Int = 0
    @State private var end: Int = 0
    @State private var sOverlap: Int = 0
    @State private var feather: Int = 0
    @State private var cropL: Int = 0
    @State private var cropR: Int = 0
    @State private var group: Int = 0   // 0 上下 1 左右

    private var item: ShotItem? {
        model.items.indices.contains(index) ? model.items[index] : nil
    }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    content(item)
                } else {
                    Text("这张截图已被移除").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(item.map { _ in "第 \(index + 1) 张" } ?? "校准")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { apply() }.bold()
                }
            }
        }
        .onAppear(perform: sync)
    }

    private func sync() {
        guard let it = item else { return }
        start = it.keepStart
        end = it.keepEnd
        sOverlap = it.s
        feather = it.feather
        cropL = model.cropLeft
        let w = it.pixelWidth
        cropR = model.cropRight > 0 ? model.cropRight : 0
        _ = w
    }

    private func apply() {
        guard let it = item else { dismiss(); return }
        model.applyManual(index: index, start: start, end: end, newS: sOverlap)
        // 左右是全局参数
        let w = it.pixelWidth
        model.cropLeft = max(0, min(cropL, max(0, w - 8)))
        model.cropRight = max(0, min(cropR, max(0, w - model.cropLeft - 8)))
        dismiss()
    }

    // MARK: - 内容

    private func content(_ it: ShotItem) -> some View {
        VStack(spacing: 0) {
            // 预览：显示保留区间
            ZStack {
                Color.black
                if let src = it.source {
                    Image(decorative: src, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay(alignment: .top) {
                            // 被裁掉的顶部
                            GeometryReader { geo in
                                let h = geo.size.height
                                let top = h * CGFloat(start) / CGFloat(max(1, it.pixelHeight))
                                Rectangle()
                                    .fill(.black.opacity(0.6))
                                    .frame(height: max(0, top))
                            }
                        }
                        .overlay(alignment: .bottom) {
                            GeometryReader { geo in
                                let h = geo.size.height
                                let bottom = h * CGFloat(max(0, it.pixelHeight - end)) / CGFloat(max(1, it.pixelHeight))
                                VStack {
                                    Spacer()
                                    Rectangle()
                                        .fill(.orange.opacity(0.55))
                                        .frame(height: max(0, bottom))
                                }
                            }
                        }
                }
            }
            .frame(height: 300)
            .clipped()

            Form {
                Section {
                    Picker("", selection: $group) {
                        Text("上下裁切").tag(0)
                        Text("左右裁切").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if group == 0 {
                    Section {
                        stepperRow(title: "保留起点",
                                   subtitle: "本张从这一行开始保留",
                                   value: $start,
                                   range: 0...(max(1, end - 2)),
                                   step: 1,
                                   resetTitle: "归零",
                                   onReset: { start = 0; sOverlap = 0 })
                        stepperRow(title: "保留终点",
                                   subtitle: "末端裁掉 \(max(0, it.pixelHeight - end)) px",
                                   value: $end,
                                   range: (start + 2)...it.pixelHeight,
                                   step: 1,
                                   resetTitle: "通底",
                                   onReset: { end = it.pixelHeight })
                        stepperRow(title: "软融合宽度",
                                   subtitle: "接缝处渐变过渡，消除硬边",
                                   value: $feather,
                                   range: 0...max(1, Int(Double(it.pixelHeight) * 0.08)),
                                   step: 1,
                                   resetTitle: nil,
                                   onReset: nil)
                    } footer: {
                        Text("蓝线位置＝本张保留起点（含已跳过的状态栏 \(it.c) px 与重叠内容）；共跳过 \(it.keepStart) px。")
                    }

                    Section {
                        Button("恢复为自动识别") {
                            model.resetManual(index: index)
                            sync()
                        }
                    }
                } else {
                    Section {
                        stepperRow(title: "左侧裁掉",
                                   subtitle: "从这一列开始保留",
                                   value: $cropL,
                                   range: 0...max(1, it.pixelWidth - 8),
                                   step: 1,
                                   resetTitle: "归零",
                                   onReset: { cropL = 0 })
                        stepperRow(title: "右侧裁掉",
                                   subtitle: "保留到第 \(max(0, it.pixelWidth - cropR)) 列",
                                   value: $cropR,
                                   range: 0...max(1, it.pixelWidth - cropL - 8),
                                   step: 1,
                                   resetTitle: "通右",
                                   onReset: { cropR = 0 })
                    } footer: {
                        Text("左右裁切对所有截图统一生效，用于去掉截屏两侧的黑边或留白。")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stepperRow(title: String,
                            subtitle: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>,
                            step: Int,
                            resetTitle: String?,
                            onReset: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.label2)
                }
                Spacer()
                Text("\(value.wrappedValue) px")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Theme.label2)
            }
            HStack(spacing: 10) {
                Stepper("", value: value, in: range, step: step)
                    .labelsHidden()
                if let resetTitle, let onReset {
                    Button(resetTitle, action: onReset)
                        .font(.footnote)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
