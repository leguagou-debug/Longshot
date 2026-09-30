import SwiftUI

struct SettingsView: View {
    @Environment(StitchViewModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var m = model
        NavigationStack {
            Form {
                Section("默认拼接参数") {
                    Picker("匹配灵敏度", selection: $m.sensitivity) {
                        Text("很稳").tag(1)
                        Text("稳").tag(2)
                        Text("中").tag(3)
                        Text("激进").tag(4)
                        Text("很激进").tag(5)
                    }
                    .onChange(of: model.sensitivity) { _, _ in model.recalc() }
                }

                Section {
                    Toggle("智能重叠识别", isOn: $m.smartMatch)
                        .onChange(of: model.smartMatch) { _, _ in model.recalc() }
                    Toggle("去除固定状态栏", isOn: $m.autoChrome)
                        .onChange(of: model.autoChrome) { _, _ in model.recalc() }
                    Toggle("补齐末端空白", isOn: $m.trimTrailing)
                        .onChange(of: model.trimTrailing) { _, _ in model.recalc() }
                    Toggle("拼接处融合", isOn: $m.featherEnabled)
                        .onChange(of: model.featherEnabled) { _, _ in model.recalc() }
                } header: {
                    Text("自动处理")
                } footer: {
                    Text("灵敏度越高，越激进地裁掉疑似重叠。识别不准时可调低。")
                }

                Section {
                    Picker("拼接方向", selection: $m.horizontal) {
                        Text("竖向").tag(false)
                        Text("横向").tag(true)
                    }
                    Picker("输出画质", selection: $m.quality) {
                        Text("省流").tag(0.7)
                        Text("原画").tag(1.0)
                        Text("放大").tag(1.6)
                    }
                } header: {
                    Text("输出")
                }

                Section {
                    HStack {
                        Text("长截图")
                        Spacer()
                        Text("1.0").foregroundStyle(Theme.label2)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("全部处理在本机完成")
                        Text("截图不会上传，关闭即清空。")
                            .font(.caption)
                            .foregroundStyle(Theme.label2)
                    }
                } header: {
                    Text("关于")
                }

                Section {
                    Button("恢复默认设置", role: .destructive) {
                        model.sensitivity = 3
                        model.autoChrome = true
                        model.trimTrailing = true
                        model.smartMatch = true
                        model.featherEnabled = true
                        model.quality = 1.0
                        model.horizontal = false
                        model.cropLeft = 0
                        model.cropRight = 0
                        model.recalc()
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
