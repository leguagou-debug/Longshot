import SwiftUI

/// 设计令牌。集中管理颜色和尺寸，避免散落在各个视图里。
enum Theme {
    // iOS 系统色
    static let blue = Color(red: 0, green: 0.478, blue: 1)
    static let green = Color(red: 0.204, green: 0.780, blue: 0.349)
    static let red = Color(red: 1, green: 0.231, blue: 0.188)
    static let orange = Color(red: 1, green: 0.584, blue: 0)
    static let purple = Color(red: 0.345, green: 0.337, blue: 0.839)
    static let teal = Color(red: 0.353, green: 0.784, blue: 0.980)

    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let label2 = Color(uiColor: .secondaryLabel)
    static let label3 = Color(uiColor: .tertiaryLabel)
    static let separator = Color(uiColor: .separator)
    static let fill = Color(uiColor: .tertiarySystemFill)

    static let radius: CGFloat = 16
    static let rowMinHeight: CGFloat = 52
}

/// 卡片容器：圆角 + 分组背景，和 iOS 设置页一致。
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// 分区标题
struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing).foregroundStyle(Theme.label2)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.label2)
        .textCase(nil)
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }
}

/// 带副标题的设置行
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.label2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: Theme.rowMinHeight)
    }
}

/// 行之间的细分隔线
struct RowDivider: View {
    var inset: CGFloat = 16
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

/// 状态提示条（低置信 / 重复）
struct StatusBadge: View {
    let text: String
    let level: Int   // 0 正常 1 警告 2 错误

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch level {
        case 2: return Theme.red
        case 1: return Theme.orange
        default: return Color.black.opacity(0.55)
        }
    }
}
