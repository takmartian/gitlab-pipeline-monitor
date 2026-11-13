import SwiftUI

struct ProjectGroup: Identifiable {
    let project: GitLabProject
    let pipelines: [Pipeline]
    var id: Int { project.id }
    var hasActive: Bool { pipelines.contains { $0.status.isActive } }
    var hasFailed: Bool { pipelines.contains { $0.status == .failed } }
    var latest: Pipeline? { pipelines.max { $0.sortDate < $1.sortDate } }
}

enum StatusFilter: String, CaseIterable, Hashable {
    case all, active, failed, success, other

    var title: String {
        switch self {
        case .all: return loc("全部")
        case .active: return loc("运行中")
        case .failed: return loc("失败")
        case .success: return loc("成功")
        case .other: return loc("其他")
        }
    }

    var tint: Color? {
        switch self {
        case .all: return nil
        case .active: return Color(PipelineStatus.running.color)
        case .failed: return Color(PipelineStatus.failed.color)
        case .success: return Color(PipelineStatus.success.color)
        case .other: return Color(PipelineStatus.canceled.color)
        }
    }

    func matches(_ status: PipelineStatus) -> Bool {
        switch self {
        case .all: return true
        case .active: return status.isActive
        case .failed: return status == .failed
        case .success: return status == .success
        case .other: return !status.isActive && status != .failed && status != .success
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var query = ""
    @State private var filter: StatusFilter = .all
    @State private var collapsed: Set<Int> = []
    @State private var detail: Pipeline?
    @State private var runTarget: GitLabProject?
    @State private var toast: String?
    @State private var toastTint: Color = .primary
    @FocusState private var searchFocused: Bool

    private var height: CGFloat { 560 }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                header
                Divider()
                filterBar
                content
                Divider()
                footer
            }

            if let toast {
                ToastView(text: toast, tint: toastTint)
                    .padding(.horizontal, 12)
                    .zIndex(3)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let pipeline = detail, let project = state.project(for: pipeline) {
                PipelineDetailView(project: project, pipeline: pipeline) {
                    withAnimation(.spring(duration: 0.28)) { detail = nil }
                }
                .background(PanelBackground())
                .zIndex(2)
                .transition(.move(edge: .trailing))
            }

            if let project = runTarget {
                RunPipelineView(project: project) {
                    withAnimation(.spring(duration: 0.28)) { runTarget = nil }
                }
                .background(PanelBackground())
                .zIndex(4)
                .transition(.opacity)
            }
        }
        .frame(width: CGFloat(settings.panelWidth), height: height)
        .animation(.spring(duration: 0.28), value: detail)
        .animation(.spring(duration: 0.28), value: runTarget)
        .onExitCommand {
            if detail != nil { detail = nil }
            else if runTarget != nil { runTarget = nil }
            else { AppController.shared.closePanel() }
        }
        .onChange(of: state.actionMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            toastTint = message.contains("失败") ? Color(PipelineStatus.failed.color) : .primary
            withAnimation(.spring(duration: 0.25)) { toast = message }
            state.actionMessage = nil
            Task {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeOut(duration: 0.25)) { toast = nil }
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(PipelineStatus.running.color))
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))

            VStack(alignment: .leading, spacing: 1) {
                Text(state.demoHost ?? Fmt.host(settings.normalizedBaseURL))
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let user = state.user {
                    Text("\(user.name) · @\(user.username)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let error = state.fatalErrorMessage {
                    // 错误优先于账号：令牌失效时不该继续显示上一个账号名，免得看着像连上了
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(PipelineStatus.failed.color))
                        .lineLimit(1)
                } else {
                    Text(loc("未配置"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            if state.isLoadingPipelines || state.isLoadingProjects {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            IconButton(system: "arrow.clockwise", help: loc("刷新")) { state.refresh(force: true) }
            IconButton(system: "gearshape", help: loc("设置")) { AppController.shared.showSettings() }
            IconButton(system: "power", help: loc("退出")) { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 筛选

    private var filterBar: some View {
        VStack(spacing: 7) {
            SearchField(text: $query, placeholder: loc("搜索") + " · " + loc("项目 / 分支"))
                .focused($searchFocused)

            HStack(spacing: 5) {
                ForEach(StatusFilter.allCases, id: \.self) { option in
                    FilterChip(
                        title: option.title,
                        count: counts[option] ?? 0,
                        tint: option.tint,
                        active: filter == option
                    ) {
                        withAnimation(.easeOut(duration: 0.15)) { filter = option }
                    }
                }
                Spacer(minLength: 0)
                if state.settings.refreshInterval > 0 {
                    Image(systemName: "timer")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(AppSettings.refreshIntervalLabel(state.settings.refreshInterval))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var counts: [StatusFilter: Int] {
        var result: [StatusFilter: Int] = [:]
        let all = state.allVisiblePipelines
        for option in StatusFilter.allCases {
            result[option] = all.filter { option.matches($0.status) }.count
        }
        return result
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if !settings.isConfigured {
            EmptyStateView(
                icon: "link",
                title: loc("未配置 GitLab 连接"),
                message: loc("填写服务器地址和访问令牌后，这里会显示你打星项目的流水线。"),
                actionTitle: loc("开始配置")
            ) {
                AppController.shared.showSettings()
            }
            .frame(maxHeight: .infinity)
        } else if state.monitoredProjects.isEmpty {
            EmptyStateView(
                icon: "star",
                title: loc("没有可监控的项目"),
                message: loc("在设置里勾选要监控的项目，或开启「仅监控星标项目」。"),
                actionTitle: loc("设置")
            ) {
                AppController.shared.showSettings(tab: .projects)
            }
            .frame(maxHeight: .infinity)
        } else if let error = state.fatalErrorMessage, groups.isEmpty {
            EmptyStateView(
                icon: "wifi.exclamationmark",
                title: loc("连接失败"),
                message: error,
                tint: Color(PipelineStatus.failed.color),
                actionTitle: loc("重新加载")
            ) {
                state.refresh(force: true)
            }
            .frame(maxHeight: .infinity)
        } else if groups.isEmpty {
            EmptyStateView(
                icon: state.allVisiblePipelines.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                title: state.allVisiblePipelines.isEmpty ? loc("暂无流水线记录") : loc("没有符合筛选条件的流水线"),
                message: state.allVisiblePipelines.isEmpty ? nil : loc("试试切换筛选或清空搜索。")
            )
            .frame(maxHeight: .infinity)
        } else {
            list
        }
    }

    private var groups: [ProjectGroup] {
        let needle = query.trimmed.lowercased()
        var result: [ProjectGroup] = []
        for project in state.monitoredProjects {
            let all = (state.pipelines[project.id] ?? []).sorted { $0.sortDate > $1.sortDate }
            let matched = all.filter { pipeline in
                filter.matches(pipeline.status)
                    && (needle.isEmpty
                        || project.pathWithNamespace.lowercased().contains(needle)
                        || project.name.lowercased().contains(needle)
                        || pipeline.ref.lowercased().contains(needle)
                        || pipeline.shortSHA.lowercased().contains(needle)
                        || (pipeline.name?.lowercased().contains(needle) ?? false))
            }
            if !matched.isEmpty {
                result.append(ProjectGroup(project: project, pipelines: matched))
            } else if filter == .all && needle.isEmpty && !all.isEmpty {
                result.append(ProjectGroup(project: project, pipelines: all))
            } else if filter == .all && needle.isEmpty && all.isEmpty {
                result.append(ProjectGroup(project: project, pipelines: []))
            }
        }
        return result.sorted { left, right in
            if left.hasActive != right.hasActive { return left.hasActive }
            if left.hasFailed != right.hasFailed { return left.hasFailed }
            return (left.latest?.sortDate ?? .distantPast) > (right.latest?.sortDate ?? .distantPast)
        }
    }

    private var list: some View {
        ScrollView {
            // 菜单栏面板里项目数量有限，用普通 VStack：首屏就能全部绘制，不会出现懒加载未就绪的空白
            VStack(alignment: .leading, spacing: 2) {
                ForEach(groups) { group in
                    ProjectSectionView(
                        group: group,
                        collapsed: collapsed.contains(group.project.id),
                        onToggleCollapse: { toggle(group.project.id) },
                        onOpen: { detail = $0 },
                        onRun: { runTarget = group.project }
                    )
                    .id(group.project.id)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.automatic)
    }

    private func toggle(_ id: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(locf("更新于 %@", Fmt.clock(state.lastUpdated)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            Text(locf("共 %d 个项目 · %d 条流水线", state.monitoredProjects.count, state.allVisiblePipelines.count))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            IconButton(system: "safari", help: loc("打开 GitLab")) {
                openURL(settings.normalizedBaseURL?.absoluteString)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// 详情页/运行页的整块背景，遮住后面的列表（动态色会自动跟随明暗外观）
struct PanelBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
    }
}
