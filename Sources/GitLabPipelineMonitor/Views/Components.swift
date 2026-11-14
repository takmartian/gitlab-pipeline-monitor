import SwiftUI

// MARK: - 状态图标（运行中会转）

struct StatusIcon: View {
    let status: PipelineStatus
    var size: CGFloat = 14

    var body: some View {
        Group {
            if status == .running {
                // 只有运行中才渲染旋转视图，用 TimelineView 按时间算角度。
                // 之前用 withAnimation(.repeatForever) + @State，流水线跑完变成「已通过」后
                // 那个无限动画不会自己停，勾会被转到某个角度（看着像个「r」）
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 1.1) / 1.1
                    icon.rotationEffect(.degrees(phase * 360))
                }
            } else {
                icon
            }
        }
        .help(status.label)
    }

    private var icon: some View {
        Image(systemName: status.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(Color(status.color))
    }
}

// MARK: - 小图标按钮

struct IconButton: View {
    let system: String
    var help: String? = nil
    var tint: Color = .primary
    var size: CGFloat = 12
    /// 点击框尺寸：调用方可按所在行的高度收窄，避免 hover 出现图标时把行高撑开
    var box: CGSize = CGSize(width: 24, height: 22)
    var action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: box.width, height: box.height)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hover ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(OptionalHelp(text: help))
    }

    private struct OptionalHelp: ViewModifier {
        let text: String?
        func body(content: Content) -> some View {
            if let text { content.help(text) } else { content }
        }
    }
}

// MARK: - 筛选胶囊

struct FilterChip: View {
    let title: String
    var count: Int? = nil
    var tint: Color? = nil
    let active: Bool
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let tint {
                    Circle().fill(tint).frame(width: 6, height: 6)
                }
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active ? Color.primary : Color.secondary)
                }
            }
            .font(.system(size: 11, weight: active ? .semibold : .regular))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(active ? Color.accentColor.opacity(0.18) : (hover ? Color.primary.opacity(0.06) : Color.clear))
            )
            .overlay(
                Capsule().strokeBorder(active ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var tint: Color = .secondary
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - 顶部提示

struct ToastView: View {
    let text: String
    var tint: Color = .primary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
                .font(.system(size: 12))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(3)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

// MARK: - 搜索框

struct SearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            // 占位文字自己画，不要用 TextField(placeholder, text:)：
            // 那个初始化器的标题在 Form 里会被 SwiftUI 当成「行标签」提到左边一列，
            // 真正的输入框反而被挤到右边（光标和输入的文字都贴着右边缘）。
            ZStack(alignment: .leading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .labelsHidden()
            }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

// MARK: - 行悬停背景

struct RowHighlight: ViewModifier {
    @State private var hover = false
    var corner: CGFloat = 7

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(hover ? Color.primary.opacity(0.055) : Color.clear)
            )
            .onHover { hover = $0 }
    }
}

extension View {
    func rowHighlight() -> some View { modifier(RowHighlight()) }
}
