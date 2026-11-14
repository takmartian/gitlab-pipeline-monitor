import SwiftUI

struct PipelineDetailView: View {
    let project: GitLabProject
    let pipeline: Pipeline
    let onBack: () -> Void
    /// 预填数据：快照/离线预览用，避免等异步
    var initialJobs: [Job] = []
    var initialCommit: Commit?

    @EnvironmentObject var state: AppState
    @State private var jobs: [Job]
    @State private var jobsError: String?
    @State private var loadingJobs = false
    @State private var commit: Commit?

    init(project: GitLabProject, pipeline: Pipeline, onBack: @escaping () -> Void,
         initialJobs: [Job] = [], initialCommit: Commit? = nil) {
        self.project = project
        self.pipeline = pipeline
        self.onBack = onBack
        self.initialJobs = initialJobs
        self.initialCommit = initialCommit
        _jobs = State(initialValue: initialJobs)
        _commit = State(initialValue: initialCommit)
    }

    private var busy: Bool {
        state.busyAction == "pipeline-\(pipeline.id)-retry" || state.busyAction == "pipeline-\(pipeline.id)-cancel"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    summary
                    if let commit, let title = commit.title, !title.isEmpty {
                        card(title: loc("提交信息")) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title).font(.system(size: 11, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                                if let author = commit.authorName {
                                    Text(author).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    jobsSection
                }
                .padding(10)
            }
            Divider()
            actions
        }
        .task(id: pipeline.id) { await load() }
    }

    // MARK: - 加载

    private func load() async {
        guard jobs.isEmpty else { return }
        loadingJobs = true
        jobsError = nil
        let result = await state.fetchJobs(projectID: project.id, pipelineID: pipeline.id,
                                             pipeline: pipeline, project: project)
        switch result {
        case .success(let list):
            jobs = list
            jobsError = nil
        case .failure(let error):
            jobs = []
            jobsError = (error as? GitLabError)?.message ?? error.localizedDescription
        }
        loadingJobs = false

        if commit == nil {
            commit = await state.fetchCommit(projectID: project.id, sha: pipeline.sha, pipeline: pipeline)
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(system: "chevron.left", help: loc("关闭"), action: onBack)
            VStack(alignment: .leading, spacing: 1) {
                Text(loc("流水线详情"))
                    .font(.system(size: 11, weight: .semibold))
                Text(project.pathWithNamespace)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            StatusIcon(status: pipeline.status, size: 15)
            Text(pipeline.status.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color(pipeline.status.color))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 概要

    private var summary: some View {
        card(title: "\(loc("流水线")) #\(pipeline.iid)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    metaKey(loc("分支"))
                    HStack(spacing: 4) {
                        Text(pipeline.ref).font(.system(size: 11, weight: .medium))
                        Button {
                            copyToPasteboard(pipeline.ref)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 9))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                        .help(loc("复制分支名"))
                        Spacer()
                    }
                }
                GridRow {
                    metaKey(loc("提交"))
                    HStack(spacing: 4) {
                        Text(pipeline.shortSHA).font(.system(size: 11, design: .monospaced))
                        Spacer()
                    }
                }
                if let source = pipeline.source, !source.isEmpty {
                    GridRow {
                        metaKey(loc("触发方式"))
                        HStack { Text(source).font(.system(size: 11)); Spacer() }
                    }
                }
                if let user = pipeline.user {
                    GridRow {
                        metaKey(loc("作者"))
                        HStack { Text("\(user.name) · @\(user.username)").font(.system(size: 11)).lineLimit(1); Spacer() }
                    }
                }
                GridRow {
                    metaKey(loc("耗时"))
                    HStack { Text(Fmt.duration(pipeline.duration)).font(.system(size: 11)); Spacer() }
                }
                GridRow {
                    metaKey(loc("开始时间"))
                    HStack { Text(Fmt.relative(pipeline.startedAt ?? pipeline.createdAt)).font(.system(size: 11)); Spacer() }
                }
                if let finished = pipeline.finishedAt {
                    GridRow {
                        metaKey(loc("结束时间"))
                        HStack { Text(Fmt.relative(finished)).font(.system(size: 11)); Spacer() }
                    }
                }
                if let covered = pipeline.covered, !covered.isEmpty {
                    GridRow {
                        metaKey(loc("覆盖率"))
                        HStack { Text(covered).font(.system(size: 11)); Spacer() }
                    }
                }
            }
        }
    }

    private func metaKey(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .leading)
    }

    // MARK: - 作业

    private var stages: [(name: String, jobs: [Job])] {
        var order: [String] = []
        var buckets: [String: [Job]] = [:]
        for job in jobs {
            if buckets[job.stage] == nil { order.append(job.stage) }
            buckets[job.stage, default: []].append(job)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var jobsSection: some View {
        card(title: loc("作业")) {
            if loadingJobs {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text(loc("加载中…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let error = jobsError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(PipelineStatus.blocked.color))
                    Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    Spacer()
                    Button(loc("重试")) { Task { await load() } }.controlSize(.small)
                }
            } else if jobs.isEmpty {
                Text(loc("无作业")).font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(stages, id: \.0) { stage in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stage.name)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .textCase(.uppercase)
                            ForEach(stage.jobs) { job in
                                JobRowView(job: job, projectID: project.id, project: project)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 底部操作

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.retry(pipeline)
            } label: {
                Label(loc("重跑流水线"), systemImage: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(!pipeline.status.canRetry || busy)

            Button {
                state.cancel(pipeline)
            } label: {
                Label(loc("停止流水线"), systemImage: "stop.fill")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .disabled(!pipeline.status.canCancel || busy)

            Spacer()

            Button {
                let base = state.settings.normalizedBaseURL
                openURL(project.pipelineURL(pipeline, base: base), base: base)
            } label: {
                Label(loc("打开流水线页面"), systemImage: "safari")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 卡片容器

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct JobRowView: View {
    let job: Job
    let projectID: Int
    let project: GitLabProject

    @EnvironmentObject var state: AppState
    @State private var hover = false

    /// 接口给了 web_url 就用它，没给也能按项目地址拼出来（以前只看 web_url，
    /// 而 web_url 因为解码问题恒为空，这个按钮从来没出现过）
    private var jobURL: String {
        job.resolvedWebURL(base: state.settings.normalizedBaseURL, project: project)
    }

    private var busy: Bool {
        state.busyAction == "job-\(job.id)-retry" || state.busyAction == "job-\(job.id)-cancel"
    }

    var body: some View {
        HStack(spacing: 7) {
            StatusIcon(status: job.status, size: 11)
            Text(job.name)
                .font(.system(size: 11))
                .lineLimit(1)
            if job.allowFailure == true, job.status == .failed {
                Text(loc("允许失败"))
                    .font(.system(size: 9))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            } else {
                if job.duration != nil {
                    Text(Fmt.duration(job.duration))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                if hover {
                    if job.status.canRetry {
                        IconButton(system: "arrow.clockwise", help: loc("重跑作业"), size: 10, box: CGSize(width: 20, height: 18)) { state.retryJob(job, projectID: projectID) }
                    }
                    if job.status.canCancel {
                        IconButton(system: "stop.circle", help: loc("停止作业"), size: 10, box: CGSize(width: 20, height: 18)) { state.cancelJob(job, projectID: projectID) }
                    }
                    if !jobURL.isEmpty {
                        IconButton(system: "text.viewfinder", help: loc("查看作业日志"), size: 10, box: CGSize(width: 20, height: 18)) {
                            openURL(jobURL, base: state.settings.normalizedBaseURL)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 24)
        .background(hover ? Color.primary.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .onHover { hover = $0 }
        .contextMenu {
            if !jobURL.isEmpty { Button(loc("查看作业日志")) { openURL(jobURL, base: state.settings.normalizedBaseURL) } }
            if job.status.canRetry { Button(loc("重跑作业")) { state.retryJob(job, projectID: projectID) } }
            if job.status.canCancel { Button(loc("停止作业")) { state.cancelJob(job, projectID: projectID) } }
        }
        .help(job.failureReason ?? job.name)
    }
}
