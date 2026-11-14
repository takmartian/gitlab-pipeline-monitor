import Foundation
import Combine
import AppKit

/// 菜单栏图标要表达的整体状态
enum AggregateStatus: Hashable {
    case none       // 没有数据
    case ok         // 最新流水线都通过
    case running    // 有流水线在跑
    case pending    // 排队/准备中
    case failed     // 有失败的
    case error      // 连接本身有问题

    var color: NSColor {
        switch self {
        case .none: return .secondaryLabelColor
        case .ok: return PipelineStatus.success.color
        case .running: return PipelineStatus.running.color
        case .pending: return PipelineStatus.pending.color
        case .failed: return PipelineStatus.failed.color
        case .error: return NSColor(srgbRed: 0.62, green: 0.62, blue: 0.66, alpha: 1)
        }
    }
}

/// 一次「某项目的流水线」拉取结果（跨任务传递用结构体，不用元组）
struct PipelineFetch {
    let projectID: Int
    let result: Result<[Pipeline], Error>
}

/// 一次「单条流水线详情」拉取结果，同样用结构体
struct PipelineDetailFetch {
    let projectID: Int
    let pipelineID: Int
    let detail: Pipeline?
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - 对外状态
    @Published var user: GitLabUser?
    @Published var gitlabVersion: String?
    @Published var starredProjects: [GitLabProject] = []
    @Published var memberProjects: [GitLabProject] = []
    @Published var pipelines: [Int: [Pipeline]] = [:]
    /// 单个项目的流水线加载错误（不至于整页崩）
    @Published var projectErrors: [Int: String] = [:]
    @Published var lastUpdated: Date?
    @Published var isLoadingProjects = false
    @Published var isLoadingPipelines = false
    /// 整体性错误：401 / 地址错 / 网络不通
    @Published var fatalErrorMessage: String?
    /// 最近一次操作（重试、取消等）的反馈
    @Published var actionMessage: String?
    @Published var busyAction: String?

    let settings: AppSettings
    /// 演示模式下顶栏显示的假主机名
    var demoHost: String?
    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var previousStatus: [Int: PipelineStatus] = [:]
    private var running = false
    /// 刷新进行中又收到 force：等这轮结束立刻补一轮
    private var pendingForce = false
    private var cancellables = Set<AnyCancellable>()

    init(settings: AppSettings) {
        self.settings = settings
        observeSettings()
        restartTimer()
    }

    // MARK: - 派生数据

    /// 星标 + 参与项目合并去重，星标优先
    var availableProjects: [GitLabProject] {
        var merged: [Int: GitLabProject] = [:]
        for project in memberProjects { merged[project.id] = project }
        for project in starredProjects { merged[project.id] = project }
        return merged.values.sorted {
            ($0.lastActivityAt ?? .distantPast) > ($1.lastActivityAt ?? .distantPast)
        }
    }

    var monitoredProjects: [GitLabProject] {
        if settings.onlyStarred {
            return starredProjects
        }
        let selected = Set(settings.monitoredProjectIDs)
        return availableProjects.filter { selected.contains($0.id) }
    }

    /// 每个监控项目的最新一条流水线：图标和汇总看这个
    var latestPerProject: [Pipeline] {
        monitoredProjects.compactMap { (pipelines[$0.id] ?? []).max { $0.sortDate < $1.sortDate } }
    }

    var allVisiblePipelines: [Pipeline] {
        monitoredProjects.flatMap { pipelines[$0.id] ?? [] }
    }

    var failingCount: Int { latestPerProject.filter { $0.status == .failed }.count }

    var aggregate: AggregateStatus {
        if fatalErrorMessage != nil, !settings.isConfigured { return .error }
        let list = latestPerProject
        if list.isEmpty { return fatalErrorMessage == nil ? .none : .error }
        if list.contains(where: { $0.status == .failed }) { return .failed }
        if list.contains(where: { $0.status == .running }) { return .running }
        if list.contains(where: { $0.status.isActive }) { return .pending }
        if list.contains(where: { $0.status == .success }) { return .ok }
        return .none
    }

    func project(for pipeline: Pipeline) -> GitLabProject? {
        if let id = pipeline.projectID {
            if let found = starredProjects.first(where: { $0.id == id }) { return found }
            if let found = memberProjects.first(where: { $0.id == id }) { return found }
            if let found = monitoredProjects.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    func client() -> GitLabClient? {
        guard let url = settings.normalizedBaseURL else { return nil }
        let token = settings.token.trimmed
        guard !token.isEmpty else { return nil }
        return GitLabClient(baseURL: url, token: token, authMode: settings.authMode)
    }

    // MARK: - 生命周期

    func bootstrap() {
        guard settings.isConfigured else { return }
        refresh(force: true)
    }

    /// 地址或令牌变了：清掉流水线数据重来。
    /// keepProjects = true 用于「同一实例换令牌」这类场景：保留项目列表，
    /// 否则刷新一慢或 momentarily 没有可用令牌，项目列表会凭空消失。
    func resetAndRefresh(keepProjects: Bool = false) {
        if !keepProjects {
            user = nil
            gitlabVersion = nil
            starredProjects = []
            memberProjects = []
        }
        pipelines = [:]
        projectErrors = [:]
        previousStatus = [:]
        lastUpdated = nil
        fatalErrorMessage = nil
        // 不 cancel 正在跑的那轮（会和 running 打架）：交给 pendingForce 合并补一轮
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        guard settings.isConfigured, !settings.demoMode else { return }
        if running {
            // 正在刷新时不再「取消 + 重启」：被取消那轮的 running 还没复位，
            // 新一轮会撞 guard !running 直接 return，整轮刷新静默空转，数据就停在半路
            // （表现为项目/流水线时不时空掉，要等下一次定时器才回来）。
            // 这里改成合并：记一笔「这轮结束后再来一轮」。
            if force { pendingForce = true }
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefresh()
        }
    }

    private func runRefresh() async {
        guard !running else { return }
        running = true
        defer {
            running = false
            if pendingForce {
                pendingForce = false
                refresh(force: true)
            }
        }
        guard let client = client() else {
            fatalErrorMessage = GitLabError(.notConfigured).message
            return
        }

        // 顶栏要显示账号（以前从来没拉过 /user，所以永远显示「未配置」）；
        // 单独一条 Task 并行拉，不串在流水线前面拖慢首屏
        if user == nil {
            Task { [weak self] in
                guard let self, let client = self.client() else { return }
                if let fetched = try? await client.currentUser() { self.user = fetched }
                if self.gitlabVersion == nil, let version = try? await client.version() {
                    self.gitlabVersion = version.version
                }
            }
        }

        let needsProjects = settings.onlyStarred ? starredProjects.isEmpty : availableProjects.isEmpty
        if needsProjects {
            await loadProjects(client: client)
        } else {
            // 星标本身会变（在 GitLab 网页上打星/取消星），每次刷新顺手同步一次，
            // 否则面板会一直停在第一次拉到的那份列表上。星标列表通常只有一个请求的量；
            // 参与项目可能几百个、要翻好几页，仍然只在需要时补拉。
            await loadStarred(client: client)
        }
        await refreshPipelines(client: client)
        lastUpdated = Date()
        onIconNeedsUpdate?()
    }

    // MARK: - 项目列表

    func loadProjects(force: Bool = false) {
        guard let client = client() else { return }
        Task { [weak self] in
            guard let self else { return }
            if force { self.starredProjects = []; self.memberProjects = [] }
            // 用户主动点「重新拉取项目列表」：星标和参与项目都要拉。
            // 否则开着「仅监控星标」时列表只剩星标，和连接页报的参与项目数对不上
            async let starredLoad: Void = self.loadStarred(client: client)
            async let memberLoad: Void = self.loadMember(client: client)
            await starredLoad
            await memberLoad
            await self.refreshPipelines(client: client)
            self.lastUpdated = Date()
            self.onIconNeedsUpdate?()
        }
    }

    private func loadProjects(client: GitLabClient) async {
        // 只监控星标时不拉「参与项目」：那可能是几百个项目、要翻好几页，
        // 每次刷新都等它的话，面板要空好几秒才能看到流水线
        if settings.onlyStarred {
            await loadStarred(client: client)
            return
        }
        async let starredFetch: Void = loadStarred(client: client)
        async let memberFetch: Void = loadMember(client: client)
        await starredFetch
        await memberFetch
    }

    private func loadStarred(client: GitLabClient) async {
        guard !isLoadingProjects else { return }
        isLoadingProjects = true
        defer { isLoadingProjects = false }
        switch await client.starredResult() {
        case .success(let list):
            starredProjects = list
            fatalErrorMessage = nil
            if settings.onlyStarred == false, settings.monitoredProjectIDs.isEmpty {
                // 第一次切到手动选择时，默认把星标项目带上，别给用户一个空列表
                settings.monitoredProjectIDs = list.map(\.id)
            }
        case .failure(let error):
            let gitLabError = error as? GitLabError ?? GitLabError(.decoding, detail: error.localizedDescription)
            fatalErrorMessage = gitLabError.message
        }
    }

    private func loadMember(client: GitLabClient) async {
        if case .success(let list) = await client.memberResult() {
            memberProjects = list
        }
    }

    /// 项目列表要显示全部可用项目（星标 + 参与）。日常自动刷新在「仅监控星标」时
    /// 不拉参与项目（可能几百个、要翻好几页），打开设置的项目页时补这一次
    func ensureMemberProjects() {
        guard memberProjects.isEmpty, let client = client() else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.loadMember(client: client)
        }
    }


    // MARK: - 流水线

    func refreshPipelines() async {
        guard let client = client() else { return }
        await refreshPipelines(client: client)
        lastUpdated = Date()
        onIconNeedsUpdate?()
    }

    private func refreshPipelines(client: GitLabClient) async {
        let targets = monitoredProjects
        guard !targets.isEmpty else {
            pipelines = [:]
            projectErrors = [:]
            return
        }
        isLoadingPipelines = true
        defer { isLoadingPipelines = false }

        let limit = max(1, min(settings.pipelinesPerProject, 20))
        var results: [Int: [Pipeline]] = [:]
        var errors: [Int: String] = [:]
        var unauthorized: String?
        let window = 6
        var start = 0

        while start < targets.count {
            let chunk = Array(targets[start..<min(start + window, targets.count)])
            start += window
            // 用自定义结构体跨任务传值，不用 (Int, Result<…>) 元组：
            // 元组在这里出现过「派发时 id 正确、消费时变成 0」的情况，
            // 于是所有流水线都被写进 pipelines[0]，面板按项目 id 取永远是空
            await withTaskGroup(of: PipelineFetch.self) { group in
                for project in chunk {
                    let projectID = project.id
                    group.addTask {
                        do {
                            return PipelineFetch(projectID: projectID,
                                               result: .success(try await client.pipelines(projectID: projectID, limit: limit)))
                        } catch {
                            return PipelineFetch(projectID: projectID, result: .failure(error))
                        }
                    }
                }
                for await fetch in group {
                    let id = fetch.projectID
                    switch fetch.result {
                    case .success(let list):
                        results[id] = list
                    case .failure(let error):
                        let gitLabError = error as? GitLabError
                        errors[id] = gitLabError?.message ?? error.localizedDescription
                        if gitLabError?.kind == .unauthorized { unauthorized = gitLabError?.message }
                    }
                }
            }
        }

        // 列表接口不返回触发人 / 耗时 / 覆盖率，逐条补一次详情
        await enrichPipelines(client: client, targets: targets, results: &results)

        if let unauthorized {
            fatalErrorMessage = unauthorized
        } else if results.isEmpty, !errors.isEmpty, targets.count == 1 {
            fatalErrorMessage = errors.values.first
        } else if !results.isEmpty {
            fatalErrorMessage = nil
        }

        notifyTransitions(results)
        pipelines = results
        projectErrors = errors
    }

    /// GitLab 的流水线列表接口不返回 user / duration / coverage，只有单条详情接口才有。
    /// 这里按面板实际要显示的范围逐条补一次详情；某条失败就保留列表里的原值，不影响其它条。
    private func enrichPipelines(client: GitLabClient, targets: [GitLabProject], results: inout [Int: [Pipeline]]) async {
        var pending: [PipelineDetailFetch] = []
        for project in targets {
            for item in results[project.id] ?? [] {
                pending.append(PipelineDetailFetch(projectID: project.id, pipelineID: item.id, detail: nil))
            }
        }
        guard !pending.isEmpty else { return }

        // 并发窗口 10：监控项目多时也不会把 GitLab 打爆
        let window = 10
        var start = 0
        while start < pending.count {
            let chunk = Array(pending[start..<min(start + window, pending.count)])
            start += window
            await withTaskGroup(of: PipelineDetailFetch.self) { group in
                for entry in chunk {
                    let projectID = entry.projectID
                    let pipelineID = entry.pipelineID
                    group.addTask {
                        let detail = try? await client.pipelineDetail(projectID: projectID, pipelineID: pipelineID)
                        return PipelineDetailFetch(projectID: projectID, pipelineID: pipelineID, detail: detail)
                    }
                }
                for await fetch in group {
                    guard let detail = fetch.detail,
                          var list = results[fetch.projectID],
                          let index = list.firstIndex(where: { $0.id == fetch.pipelineID }) else { continue }
                    list[index].mergeDetail(detail)
                    results[fetch.projectID] = list
                }
            }
        }
    }

    /// 只在"状态真的变了"时通知，避免每次刷新都弹一遍
    private func notifyTransitions(_ results: [Int: [Pipeline]]) {
        var next: [Int: PipelineStatus] = [:]
        var failures: [(project: GitLabProject, pipeline: Pipeline)] = []
        var recoveries: [(project: GitLabProject, pipeline: Pipeline)] = []

        for (projectID, list) in results {
            guard let project = (starredProjects + memberProjects).first(where: { $0.id == projectID }) else { continue }
            for pipeline in list {
                next[pipeline.id] = pipeline.status
                guard let old = previousStatus[pipeline.id], old != pipeline.status else { continue }
                if pipeline.status == .failed {
                    failures.append((project, pipeline))
                } else if pipeline.status == .success, old == .failed || old == .running {
                    recoveries.append((project, pipeline))
                }
            }
        }
        previousStatus = next

        guard settings.notifyOnFailure || settings.notifyOnRecovery else { return }
        if settings.notifyOnFailure {
            for item in failures.prefix(4) {
                Notifier.post(
                    title: loc("流水线失败"),
                    body: "\(item.project.pathWithNamespace) · \(item.pipeline.ref)",
                    id: "pipeline-\(item.pipeline.id)-failed"
                )
            }
        }
        if settings.notifyOnRecovery {
            for item in recoveries.prefix(4) {
                Notifier.post(
                    title: loc("流水线已恢复"),
                    body: "\(item.project.pathWithNamespace) · \(item.pipeline.ref)",
                    id: "pipeline-\(item.pipeline.id)-success"
                )
            }
        }
    }

    // MARK: - 操作

    func retry(_ pipeline: Pipeline) {
        guard let projectID = pipeline.projectID, let client = client() else { return }
        busyAction = "pipeline-\(pipeline.id)-retry"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.retryPipeline(projectID: projectID, pipelineID: pipeline.id)
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    func cancel(_ pipeline: Pipeline) {
        guard let projectID = pipeline.projectID, let client = client() else { return }
        busyAction = "pipeline-\(pipeline.id)-cancel"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.cancelPipeline(projectID: projectID, pipelineID: pipeline.id)
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    /// 打星 / 取消打星：成功后本地立刻改标记，监控范围随之变化
    func setStarred(_ project: GitLabProject, starred: Bool) {
        guard let client = client() else { return }
        busyAction = "star-\(project.id)"
        Task { [weak self] in
            guard let self else { return }
            do {
                if starred {
                    _ = try await client.star(projectID: project.id)
                } else {
                    _ = try await client.unstar(projectID: project.id)
                }
                self.applyStar(project.id, starred: starred)
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    private func applyStar(_ id: Int, starred: Bool) {
        if let index = starredProjects.firstIndex(where: { $0.id == id }) {
            starredProjects[index].starred = starred
            if !starred { starredProjects.remove(at: index) }
        } else if starred, let index = memberProjects.firstIndex(where: { $0.id == id }) {
            var project = memberProjects[index]
            project.starred = true
            project.starCount += 1
            starredProjects.insert(project, at: 0)
        }
        if let index = memberProjects.firstIndex(where: { $0.id == id }) {
            memberProjects[index].starred = starred
            memberProjects[index].starCount = max(0, memberProjects[index].starCount + (starred ? 1 : -1))
        }
        if !starred {
            var ids = settings.monitoredProjectIDs
            ids.removeAll { $0 == id }
            settings.monitoredProjectIDs = ids
        }
    }

    func runPipeline(project: GitLabProject, ref: String) {
        guard let client = client() else { return }
        busyAction = "project-\(project.id)-run"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.createPipeline(projectID: project.id, ref: ref)
                self.actionMessage = loc("流水线已创建")
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    func retryJob(_ job: Job, projectID: Int) {
        guard let client = client() else { return }
        busyAction = "job-\(job.id)-retry"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.retryJob(projectID: projectID, jobID: job.id)
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    func cancelJob(_ job: Job, projectID: Int) {
        guard let client = client() else { return }
        busyAction = "job-\(job.id)-cancel"
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await client.cancelJob(projectID: projectID, jobID: job.id)
                await self.refreshPipelines()
            } catch {
                self.actionMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
            self.busyAction = nil
        }
    }

    // MARK: - 详情数据

    func fetchJobs(projectID: Int, pipelineID: Int, pipeline: Pipeline? = nil, project: GitLabProject? = nil) async -> Result<[Job], Error> {
        if settings.demoMode, let pipeline, let project {
            return .success(DemoData.jobs(for: pipeline, project: project))
        }
        guard let client = client() else { return .failure(GitLabError(.notConfigured)) }
        do {
            return .success(try await client.jobs(projectID: projectID, pipelineID: pipelineID))
        } catch {
            return .failure(error)
        }
    }

    func fetchBranches(projectID: Int) async -> Result<[Branch], Error> {
        guard let client = client() else { return .failure(GitLabError(.notConfigured)) }
        do {
            return .success(try await client.branches(projectID: projectID))
        } catch {
            return .failure(error)
        }
    }

    func fetchCommit(projectID: Int, sha: String, pipeline: Pipeline? = nil) async -> Commit? {
        if settings.demoMode, let pipeline { return DemoData.commit(for: pipeline) }
        guard let client = client() else { return nil }
        return try? await client.commit(projectID: projectID, sha: sha)
    }

    // MARK: - 连接测试

    struct TestResult {
        var user: GitLabUser
        var version: String?
        var starredCount: Int
        var memberCount: Int
    }

    func testConnection() async -> Result<TestResult, Error> {
        guard let client = client() else { return .failure(GitLabError(.notConfigured)) }
        do {
            let user = try await client.currentUser()
            let version = try? await client.version()
            let starred = (try? await client.starredProjects()) ?? []
            let member = (try? await client.memberProjects()) ?? []
            return .success(TestResult(user: user, version: version?.version,
                                       starredCount: starred.count, memberCount: member.count))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 定时器 / 观察

    var onIconNeedsUpdate: (() -> Void)?

    func restartTimer() {
        timer?.invalidate()
        timer = nil
        let interval = settings.refreshInterval
        guard interval > 0 else { return }
        let newTimer = Timer(timeInterval: Double(interval), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func observeSettings() {
        // 注意 removeDuplicates().dropFirst() 的顺序：
        // @Published 在订阅时会先发一次当前值，dropFirst 丢掉它；
        // 而 SwiftUI 的输入框在挂载时会把**同一个值写回**绑定，又触发一次相同值的发射 ——
        // 不去重的话，打开设置窗口就会误触发「地址变了」，把项目列表整个清空重拉（面板会闪一下空）。
        // removeDuplicates 记住的基准值就是订阅时的当前值，相同值直接吞掉。
        settings.$refreshInterval.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.restartTimer() } }
            .store(in: &cancellables)

        settings.$serverURL.removeDuplicates().dropFirst()
            .debounce(for: .seconds(1.0), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.resetAndRefresh() } }
            .store(in: &cancellables)

        // 换令牌：同一台服务器，项目列表没必要清空（清空后如果这次刷新没成功，列表就一直空着）
        settings.$token.removeDuplicates().dropFirst()
            .debounce(for: .seconds(1.2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.resetAndRefresh(keepProjects: true) } }
            .store(in: &cancellables)

        settings.$onlyStarred.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.resetAndRefresh(keepProjects: true); self?.ensureMemberProjects() } }
            .store(in: &cancellables)

        settings.$monitoredProjectIDs.removeDuplicates().dropFirst()
            .debounce(for: .seconds(0.4), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        settings.$pipelinesPerProject.removeDuplicates().dropFirst()
            .debounce(for: .seconds(0.5), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(force: true) } }
            .store(in: &cancellables)

        settings.$language.removeDuplicates().dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.objectWillChange.send() } }
            .store(in: &cancellables)
    }
}

extension GitLabClient {
    /// 把 throwing 调用包成 Result，方便并发聚合错误
    func starredResult() async -> Result<[GitLabProject], Error> {
        do {
            return .success(try await starredProjects())
        } catch {
            return .failure(error)
        }
    }

    func memberResult() async -> Result<[GitLabProject], Error> {
        do {
            return .success(try await memberProjects())
        } catch {
            return .failure(error)
        }
    }
}
