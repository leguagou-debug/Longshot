import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(StitchViewModel.self) private var model
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showSettings = false
    @State private var cropTarget: CropTarget?
    @State private var goResult = false

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            ZStack {
                Theme.groupedBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("长截图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickerItems,
                                 maxSelectionCount: 300,
                                 matching: .images,
                                 photoLibrary: .shared()) {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.items.isEmpty { bottomBar }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(item: $cropTarget) { t in CropSheet(index: t.index) }
            .navigationDestination(isPresented: $goResult) { ResultView() }
            .onChange(of: pickerItems) { _, newValue in
                guard !newValue.isEmpty else { return }
                Task { await loadPicked(newValue) }
            }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                if model.items.isEmpty {
                    emptyState
                } else {
                    previewCard
                    SectionHeader(title: "截图顺序",
                                  trailing: "共 \(model.items.count) 张 · 长图约 \(model.estimatedHeight) px")
                    listCard
                    optionsSection
                    Button(role: .destructive) {
                        model.clear()
                    } label: {
                        Text("清空全部截图").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.red)
                    .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                LinearGradient(colors: [Theme.teal, Theme.blue, Theme.purple],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 116, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.blue.opacity(0.32), radius: 18, y: 10)

            Text("把截图拼成一张长图")
                .font(.title2.bold())
            Text("选择多张连续滚动的截图，自动识别重叠区域并无缝拼接，同时去掉每张都重复的状态栏。")
                .font(.subheadline)
                .foregroundStyle(Theme.label2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)

            PhotosPicker(selection: $pickerItems,
                         maxSelectionCount: 300,
                         matching: .images,
                         photoLibrary: .shared()) {
                Label("选择截图", systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)

            Button("没有截图？用示例体验") {
                model.add(ShotItem.makeDemo())
            }
            .font(.subheadline)
            .padding(.top, 2)
        }
        .padding(.vertical, 28)
    }

    private var previewCard: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                let w = model.items.first?.pixelWidth ?? 0
                let h = max(1, model.estimatedHeight)
                let l = min(model.cropLeft, max(0, w - 8))
                let r = min(model.cropRight, max(0, w - l - 8))
                let uw = max(1, w - l - r)

                VStack {
                    Spacer(minLength: 0)
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.blue)
                    Spacer(minLength: 0)
                }
                .frame(width: 84, height: 148)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    Text("长图预览").font(.headline)
                    infoLine("尺寸", "\(uw) × \(h)")
                    infoLine("张数", "\(model.items.count) 张 · \(String(format: "%.1f", Double(h) / Double(uw))) 屏")
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 7, height: 7)
                        Text(statusText).font(.caption).foregroundStyle(Theme.label2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func infoLine(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).foregroundStyle(Theme.label3)
            Text(v).monospacedDigit()
        }
        .font(.caption)
    }

    private var statusColor: Color {
        if model.items.contains(where: { $0.duplicate }) { return Theme.red }
        if model.items.contains(where: { $0.lowConfidence }) { return Theme.orange }
        return Theme.green
    }

    private var statusText: String {
        let dup = model.items.filter { $0.duplicate }.count
        let low = model.items.filter { $0.lowConfidence }.count
        if dup > 0 { return "检测到 \(dup) 张可能完全重复" }
        if low > 0 { return "有 \(low) 处需要手动确认" }
        return "重叠已全部对齐"
    }

    private var listCard: some View {
        Card {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { idx, item in
                if idx > 0 { RowDivider(inset: 58) }
                Button {
                    cropTarget = CropTarget(index: idx)
                } label: {
                    rowView(idx: idx, item: item)
                }
                .buttonStyle(.plain)
            }
            Divider().padding(.leading, 16)
            Text("点按可校准裁切与重叠 · 长按拖动排序")
                .font(.caption)
                .foregroundStyle(Theme.label2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
    }

    private func rowView(idx: Int, item: ShotItem) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottom) {
                if let t = item.thumbnail {
                    Image(uiImage: t)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 68)
                        .clipped()
                } else {
                    Rectangle().fill(Theme.fill)
                        .frame(width: 44, height: 68)
                }
                StatusBadge(text: idx == 0 ? "首张" : item.statusText,
                            level: idx == 0 ? 0 : item.statusLevel)
                    .offset(y: 4)
            }
            .frame(width: 44, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(idx + 1). \(item.displayName)")
                    .font(.subheadline)
                    .lineLimit(1)
                Text("保留 \(item.keptRatio)% · 高 \(item.keptHeight) px")
                    .font(.caption2)
                    .foregroundStyle(Theme.label2)
                Text(idx == 0 ? "首张完整保留" : "跳过 \(item.keepStart) px")
                    .font(.caption2)
                    .foregroundStyle(Theme.label2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.label3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var optionsSection: some View {
        @Bindable var m = model
        return VStack(spacing: 16) {
            VStack(spacing: 6) {
                SectionHeader(title: "自动处理")
                Card {
                    SettingRow(title: "智能重叠识别", subtitle: "逐对比较像素，自动裁掉重复部分") {
                        Toggle("", isOn: $m.smartMatch)
                            .labelsHidden()
                            .onChange(of: model.smartMatch) { _, _ in model.recalc() }
                    }
                    RowDivider()
                    SettingRow(title: "去除固定状态栏", subtitle: "自动探测顶部/底部重复区域") {
                        Toggle("", isOn: $m.autoChrome)
                            .labelsHidden()
                            .onChange(of: model.autoChrome) { _, _ in model.recalc() }
                    }
                    RowDivider()
                    SettingRow(title: "补齐末端空白", subtitle: "最后一张多余留白自动裁掉") {
                        Toggle("", isOn: $m.trimTrailing)
                            .labelsHidden()
                            .onChange(of: model.trimTrailing) { _, _ in model.recalc() }
                    }
                }
            }

            VStack(spacing: 6) {
                SectionHeader(title: "输出")
                Card {
                    SettingRow(title: "拼接方向") {
                        Picker("", selection: $m.horizontal) {
                            Text("竖向").tag(false)
                            Text("横向").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    RowDivider()
                    SettingRow(title: "输出画质") {
                        Picker("", selection: $m.quality) {
                            Text("省流").tag(0.7)
                            Text("原画").tag(1.0)
                            Text("放大").tag(1.6)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }
                    RowDivider()
                    SettingRow(title: "拼接处融合", subtitle: "重叠区做渐变过渡，避免硬接缝") {
                        Toggle("", isOn: $m.featherEnabled)
                            .labelsHidden()
                            .onChange(of: model.featherEnabled) { _, _ in model.recalc() }
                    }
                }
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task {
                    await model.stitch()
                    if model.resultImage != nil { goResult = true }
                }
            } label: {
                Label("拼成长图", systemImage: "rectangle.stack.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.items.count < 2)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: - 载入

    private func loadPicked(_ items: [PhotosPickerItem]) async {
        var loaded: [ShotItem] = []
        for (i, pi) in items.enumerated() {
            if let data = try? await pi.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                loaded.append(ShotItem(image: img, name: "截图 \(i + 1)"))
            }
        }
        pickerItems = []
        guard !loaded.isEmpty else { return }
        model.add(loaded)
    }
}

/// .sheet(item:) 需要一个 Identifiable。
/// 不要给 Int 加全局 Identifiable 扩展 —— 那会影响整个 App 里所有 Int，
/// 属于典型的「看起来方便、后期难查」的写法。用专用包装类型更安全。
struct CropTarget: Identifiable, Equatable {
    let index: Int
    var id: Int { index }
}
