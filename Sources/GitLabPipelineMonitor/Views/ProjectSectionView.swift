import SwiftUI

struct ProjectSectionView: View {
    let group: ProjectGroup
    let collapsed: Bool
    let onToggleCollapse: () -> Void
    let onOpen: (Pipeline) -> Void
    let onRun: () -> Void

    @EnvironmentObject var state: AppState
    @State private var hover = false

    private var showActions: Bool { hover }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !collapsed {
                if group.pipelines.isEmpty {
                    Text(loc("暂无流水线记录"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 30)
                        .padding(.vertical, 5)
                } else {
                    ForEach(group.pipelines) { pipeline in
                        PipelineRowView(pipeline: pipeline, project: group.project, onOpen: { onOpen(pipeline) })
                    }
                }
                if let message = state.projectErrors[group.project.id] {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(PipelineStatus.blocked.color))
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.leading, 30)
                    .padding(.vertical, 4)
                }
            }
            Divider().padding(.leading, 30).opacity(0.5)
        }
        .onHover { hover = $0 }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button(action: onToggleCollapse) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)

            if group.project.starred {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(nsColor: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)))
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(group.project.shortPath)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                // 副标题恒占位：没有命名空间时也留一行高度，
                // 否则 hover 出现操作图标时会被图标撑高，行高来回跳
                Text(group.project.namespace.isEmpty ? " " : group.project.namespace)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .opacity(group.project.namespace.isEmpty ? 0 : 1)
            }

            if group.project.archived {
                Text("归档")
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let latest = group.latest {
                StatusIcon(status: latest.status, size: 11)
                Text(Fmt.relative(latest.sortDate))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .opacity(showActions ? 0 : 1)
            }

            // 图标恒占位（不 hover 时透明且不可点）：出现/消失不再改变任何布局，
            // 行高与横向都不会再跳；项目头本身也已固定高度，双重保险
            HStack(spacing: 2) {
                IconButton(
                    system: group.project.starred ? "star.fill" : "star",
                    help: group.project.starred ? loc("取消打星") : loc("打星"),
                    tint: group.project.starred ? Color(nsColor: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)) : .primary,
                    size: 10,
                    box: CGSize(width: 20, height: 18)
                ) {
                    state.setStarred(group.project, starred: !group.project.starred)
                }
                IconButton(system: "play.circle", help: loc("运行新流水线"), size: 12, box: CGSize(width: 20, height: 18)) { onRun() }
                IconButton(system: "safari", help: loc("在项目页打开"), size: 10, box: CGSize(width: 20, height: 18)) {
                    let base = state.settings.normalizedBaseURL
                    openURL(group.project.resolvedWebURL(base: base), base: base)
                }
            }
            .opacity(showActions ? 1 : 0)
            .allowsHitTesting(showActions)
        }
        .padding(.horizontal, 6)
        .frame(height: 36)
        .contentShape(Rectangle())
    }
}

struct PipelineRowView: View {
    let pipeline: Pipeline
    let project: GitLabProject
    let onOpen: () -> Void

    @EnvironmentObject var state: AppState
    @State private var hover = false

    private var busy: Bool {
        state.busyAction == "pipeline-\(pipeline.id)-retry" || state.busyAction == "pipeline-\(pipeline.id)-cancel"
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                StatusIcon(status: pipeline.status, size: 13)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(pipeline.ref)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                        Text("#" + String(pipeline.iid))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                        if let name = pipeline.name, !name.isEmpty {
                            Text(name)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    HStack(spacing: 8) {
                        MetaItem(icon: "shippingbox", text: pipeline.shortSHA)
                        MetaItem(icon: "clock", text: Fmt.relative(pipeline.sortDate))
                        if pipeline.duration != nil {
                            MetaItem(icon: "stopwatch", text: Fmt.duration(pipeline.duration))
                        }
                        if let covered = pipeline.covered, !covered.isEmpty {
                            MetaItem(icon: "checkmark.seal", text: covered)
                        }
                        if let user = pipeline.user {
                            MetaItem(icon: "person", text: user.username)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer(minLength: 4)

                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if hover {
                    HStack(spacing: 2) {
                        if pipeline.status.canRetry {
                            IconButton(system: "arrow.clockwise", help: loc("重试")) { state.retry(pipeline) }
                        }
                        if pipeline.status.canCancel {
                            IconButton(system: "stop.circle", help: loc("取消")) { state.cancel(pipeline) }
                        }
                        IconButton(system: "chevron.right", help: loc("详情"), size: 10) { onOpen() }
                    }
                } else {
                    Text(pipeline.status.label)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(pipeline.status.color))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hover ? Color.primary.opacity(0.055) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            Button(loc("详情")) { onOpen() }
            Button(loc("在项目页打开")) {
                let base = state.settings.normalizedBaseURL
                openURL(project.pipelineURL(pipeline, base: base), base: base)
            }
            Divider()
            if pipeline.status.canRetry { Button(loc("重试")) { state.retry(pipeline) } }
            if pipeline.status.canCancel { Button(loc("取消")) { state.cancel(pipeline) } }
            Divider()
            Button(loc("复制分支名")) { copyToPasteboard(pipeline.ref) }
            Button(loc("复制提交 SHA")) { copyToPasteboard(pipeline.sha) }
        }
        .help("\(project.pathWithNamespace) · \(pipeline.ref) · \(pipeline.status.label)")
    }
}

struct MetaItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            // 必须允许截断：否则这段文字的最小宽度就是整段，元信息一长整行就撑出面板宽度，
            // 连带把项目头右侧的操作图标顶到可视区外面（窄面板下点不到打星）
            Text(text)
                .font(.system(size: 10, design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.tertiary)
    }
}
