import SwiftUI
import Combine

extension View {
    /// 设置页四周留白，别让分组框贴到窗口边框
    func settingsPage() -> some View {
        padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 18)
    }
}

enum SettingsTab: String, CaseIterable, Hashable {
    case connection, projects, general, about

    var title: String {
        switch self {
        case .connection: return loc("连接")
        case .projects: return loc("项目")
        case .general: return loc("通用")
        case .about: return loc("关于")
        }
    }

    var symbol: String {
        switch self {
        case .connection: return "link"
        case .projects: return "star"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    let tabRequests: PassthroughSubject<SettingsTab, Never>

    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var tab: SettingsTab = .connection

    /// 截图用：预填项目搜索词，好确认输入文字的对齐位置
    let projectsQuery: String

    init(tabs: PassthroughSubject<SettingsTab, Never>, projectsQuery: String = "") {
        self.tabRequests = tabs
        self.projectsQuery = projectsQuery
    }

    var body: some View {
        TabView(selection: $tab) {
            ConnectionTab()
                .settingsPage()
                .tabItem { Label(SettingsTab.connection.title, systemImage: SettingsTab.connection.symbol) }
                .tag(SettingsTab.connection)

            ProjectsTab(prefillQuery: projectsQuery)
                .settingsPage()
                .tabItem { Label(SettingsTab.projects.title, systemImage: SettingsTab.projects.symbol) }
                .tag(SettingsTab.projects)

            GeneralTab()
                .settingsPage()
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }
                .tag(SettingsTab.general)

            AboutTab()
                .settingsPage()
                .tabItem { Label(SettingsTab.about.title, systemImage: SettingsTab.about.symbol) }
                .tag(SettingsTab.about)
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .frame(width: 600, height: 470)
        .onReceive(tabRequests) { tab = $0 }
    }
}

// MARK: - 连接

struct ConnectionTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    @State private var revealToken = false
    @State private var testing = false
    @State private var testOK: Bool?
    @State private var testMessage: String?
    @State private var testInfo: AppState.TestResult?
    @State private var loadingProjects = false

    var body: some View {
        Form {
            Section(loc("服务器地址")) {
                TextField(loc("地址"), text: $settings.serverURL, prompt: Text("https://gitlab.example.com"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                Picker(loc("令牌类型"), selection: $settings.authMode) {
                    ForEach(GitLabAuthMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                HStack(spacing: 6) {
                    Group {
                        if revealToken {
                            TextField(loc("粘贴令牌"), text: $settings.token)
                        } else {
                            SecureField(loc("粘贴令牌"), text: $settings.token)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)

                    Button {
                        revealToken.toggle()
                    } label: {
                        Image(systemName: revealToken ? "eye.slash" : "eye")
                    }
                    .help(revealToken ? loc("隐藏") : loc("显示"))
                }

                Text(loc("令牌在本机加密保存（AES-GCM，密钥来自这台 Mac 和你的登录账户），不会写进配置文件。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Link(loc("创建令牌"), destination: URL(string: (settings.normalizedBaseURL?.absoluteString ?? "https://gitlab.com") + "/-/user_settings/personal_access_tokens") ?? URL(string: "https://gitlab.com")!)
                    Text("·").foregroundStyle(.tertiary)
                    Text(loc("令牌需要 read_api 权限；若还要读取未加入的项目，请加上 read_user。"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Section(loc("测试连接")) {
                HStack(spacing: 10) {
                    Button {
                        test()
                    } label: {
                        if testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).scaleEffect(0.7)
                                Text(loc("正在测试…"))
                            }
                        } else {
                            Label(loc("测试连接"), systemImage: "bolt")
                        }
                    }
                    .disabled(testing || !settings.isConfigured)

                    Button {
                        loadProjects()
                    } label: {
                        Label(loc("重新拉取项目列表"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(loadingProjects || !settings.isConfigured)

                    Spacer()
                }

                if let testOK {
                    HStack(spacing: 6) {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testOK ? Color(PipelineStatus.success.color) : Color(PipelineStatus.failed.color))
                        Text(testOK ? loc("连接成功") : (testMessage ?? loc("连接失败")))
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                }

                if testOK == true, let info = testInfo {
                    InfoRow(key: loc("登录用户"), value: "\(info.user.name) · @\(info.user.username)")
                    InfoRow(key: loc("GitLab 版本"), value: info.version ?? "—")
                    InfoRow(key: loc("项目"), value: locf("已加载 %d 个星标项目、%d 个参与项目", info.starredCount, info.memberCount))
                } else if testOK == false, let testMessage {
                    Text(testMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("改动即时生效，无需保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        testOK = nil
        Task {
            let result = await state.testConnection()
            testing = false
            switch result {
            case .success(let info):
                state.user = info.user
                state.gitlabVersion = info.version
                testOK = true
                testInfo = info
                state.refresh(force: true)
                // 连接成功后把参与项目也带上，项目页立刻能看到全部项目
                state.ensureMemberProjects()
            case .failure(let error):
                testOK = false
                testInfo = nil
                testMessage = (error as? GitLabError)?.message ?? error.localizedDescription
            }
        }
    }

    private func loadProjects() {
        loadingProjects = true
        state.loadProjects(force: true)
        // 项目列表是异步拉取的，这里给个短延时让按钮状态回到可用
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            loadingProjects = false
        }
    }
}

struct InfoRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(key)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 项目

struct ProjectsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @State private var query: String

    init(prefillQuery: String = "") {
        _query = State(initialValue: prefillQuery)
    }

    private var available: [GitLabProject] {
        let needle = query.trimmed.lowercased()
        let list = state.availableProjects
        return needle.isEmpty ? list : list.filter {
            $0.pathWithNamespace.lowercased().contains(needle) || $0.name.lowercased().contains(needle)
        }
    }

    private var starColor: Color { Color(nsColor: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)) }

    private var monitoredCount: Int { settings.onlyStarred ? state.starredProjects.count : settings.monitoredProjectIDs.count }

    var body: some View {
        Form {
            Section {
                Toggle(loc("仅监控星标项目"), isOn: $settings.onlyStarred)
                Text(loc("开启后只监控你打过星的项目；关闭后可在下方手动勾选。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(loc("项目")) {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(starColor)
                    Text(loc("星标") + " " + String(state.starredProjects.count))
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(loc("参与") + " " + String(state.memberProjects.count))
                    Text("·").foregroundStyle(.tertiary)
                    Image(systemName: "eye").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text(loc("监控中") + " " + String(monitoredCount))
                    Spacer()
                    if state.isLoadingProjects && state.memberProjects.isEmpty {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text(loc("正在加载参与项目…"))
                    }
                    if !settings.onlyStarred {
                        Button(loc("全选")) { selectAll() }.controlSize(.small)
                        Button(loc("清空")) { settings.monitoredProjectIDs = [] }.controlSize(.small)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

                // 不写「搜索」占位：这一行上面已经有「星标 / 参与 / 监控中」的计数，
                // 再放一个「搜索」既重复、又会被 Form 提到左边当成行标签
                SearchField(text: $query, placeholder: "")

                if state.availableProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(loc("还没有项目"))
                            .font(.system(size: 11, weight: .medium))
                        Text(loc("先在「连接」里填好地址和令牌，再点「重新拉取项目列表」；列表出来后点行首的星标就能打星。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(loc("重新拉取项目列表")) { state.loadProjects(force: true) }
                            .controlSize(.small)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(available) { project in
                                ProjectPickRow(
                                    project: project,
                                    showCheckbox: !settings.onlyStarred,
                                    monitored: binding(for: project.id)
                                )
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 260)
                }
            }

            Section(loc("每个项目显示的流水线数")) {
                Stepper(value: $settings.pipelinesPerProject, in: 1...20) {
                    Text(locf("每 %d 条", settings.pipelinesPerProject))
                        .font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
        // 平时只监控星标不拉「参与项目」，用到手动选择时补一次
        .onAppear { state.ensureMemberProjects() }
    }

    private func binding(for id: Int) -> Binding<Bool> {
        Binding(
            get: { settings.monitoredProjectIDs.contains(id) },
            set: { on in
                if on {
                    if !settings.monitoredProjectIDs.contains(id) { settings.monitoredProjectIDs.append(id) }
                } else {
                    settings.monitoredProjectIDs.removeAll { $0 == id }
                }
            }
        )
    }

    private func selectAll() {
        settings.monitoredProjectIDs = available.map(\.id)
    }
}

/// 项目行：星标（打星/取消）+ 名称 + 是否监控 + 打开网页
private struct ProjectPickRow: View {
    let project: GitLabProject
    let showCheckbox: Bool
    @Binding var monitored: Bool

    @EnvironmentObject var state: AppState
    @State private var hover = false

    private var busy: Bool { state.busyAction == "star-\(project.id)" }

    private var starColor: Color { Color(nsColor: NSColor(srgbRed: 0.96, green: 0.72, blue: 0.20, alpha: 1)) }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                state.setStarred(project, starred: !project.starred)
            } label: {
                Image(systemName: project.starred ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(project.starred ? starColor : Color.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(project.starred ? loc("取消打星") : loc("打星"))

            Text(project.shortPath)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Text(project.namespace)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 6)

            if let date = project.lastActivityAt {
                Text(Fmt.relative(date))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if busy {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            if showCheckbox {
                Toggle("", isOn: $monitored)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            Button {
                let base = state.settings.normalizedBaseURL
                openURL(project.resolvedWebURL(base: base), base: base)
            } label: {
                Image(systemName: "safari").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help(loc("在项目页打开"))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover ? Color.primary.opacity(0.05) : Color.clear)
        )
        .onHover { hover = $0 }
    }
}

// MARK: - 通用

struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section(loc("通用")) {
                Picker(loc("语言"), selection: $settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }

                Picker(loc("自动刷新"), selection: $settings.refreshInterval) {
                    ForEach(AppSettings.refreshIntervals, id: \.self) { seconds in
                        Text(AppSettings.refreshIntervalLabel(seconds)).tag(seconds)
                    }
                }

                Picker(loc("面板宽度"), selection: $settings.panelWidth) {
                    ForEach(AppSettings.panelWidths, id: \.self) { width in
                        Text("\(width) pt").tag(width)
                    }
                }

                Toggle(loc("打开面板时自动刷新"), isOn: $settings.refreshOnOpen)
            }

            Section(loc("菜单栏图标")) {
                Toggle(loc("菜单栏图标显示状态"), isOn: $settings.showStatusBadge)
                Toggle(loc("显示失败数量"), isOn: $settings.showFailureCount)
                    .disabled(!settings.showStatusBadge)
            }

            Section(loc("更新")) {
                Toggle(loc("自动检查更新"), isOn: $settings.autoUpdateEnabled)
                Text(loc("开启后每天自动检查一次，发现新版本会弹窗展示更新内容，由你决定立即更新还是忽略此版本。"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let ignored = settings.ignoredUpdateVersion {
                    HStack(spacing: 6) {
                        Text(locf("已忽略 %@ 的更新提示", ignored))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(loc("取消忽略")) { settings.ignoredUpdateVersion = nil }
                            .controlSize(.small)
                    }
                }
            }

            Section {
                Toggle(loc("流水线失败时通知"), isOn: $settings.notifyOnFailure)
                Toggle(loc("流水线恢复时通知"), isOn: $settings.notifyOnRecovery)
                if !Notifier.isReady {
                    HStack(spacing: 6) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Text(loc("系统未授权通知，请在「系统设置 → 通知」中开启。"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(loc("登录时启动"), isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于

struct AboutTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var updater: UpdateManager

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .padding(.top, 22)

            Text(AppInfo.name)
                .font(.system(size: 17, weight: .bold))

            Text(locf("版本 %@ (%@)", AppInfo.version, AppInfo.build))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            updateRow

            Text(loc("原生 SwiftUI + AppKit 菜单栏应用，无 Electron、无外部依赖。"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 4) {
                InfoRow(key: loc("服务器"), value: Fmt.host(settings.normalizedBaseURL))
                InfoRow(key: loc("项目"), value: locf("共 %d 个项目 · %d 条流水线", state.monitoredProjects.count, state.allVisiblePipelines.count))
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()

            HStack(spacing: 10) {
                Button(loc("复制诊断信息")) { copyToPasteboard(diagnostics()) }
                Button(loc("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: AppInfo.bundlePath)])
                }
                Button(loc("退出")) { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 更新状态 + 检查 / 更新按钮
    private var updateRow: some View {
        HStack(spacing: 8) {
            Text(updateStatus)
                .font(.system(size: 11))
                .foregroundStyle(updateTint)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(loc("检查更新")) {
                Task { @MainActor in await updater.check(force: true) }
            }
            .controlSize(.small)
            .disabled(updater.phase.isBusy)
            if let latest = updater.latestVersion {
                Button(locf("更新到 %@", latest)) { updater.presentUpdateNotice() }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity)
    }

    private var updateStatus: String {
        switch updater.phase {
        case .checking: return loc("正在检查更新…")
        case .downloading: return loc("正在下载更新…")
        case .installing: return loc("正在安装更新…")
        case .failed(let message): return message
        case .upToDate: return loc("已是最新版本")
        case .idle:
            if let latest = updater.latestVersion { return locf("有新版本 %@", latest) }
            return loc("更新源：GitHub Release")
        }
    }

    private var updateTint: Color {
        if case .failed = updater.phase { return Color(PipelineStatus.failed.color) }
        if updater.updateAvailable { return Color(PipelineStatus.running.color) }
        return .secondary
    }

    private func diagnostics() -> String {
        [
            AppInfo.name + " " + AppInfo.version + " (" + AppInfo.build + ")",
            "macOS " + ProcessInfo.processInfo.operatingSystemVersionString,
            loc("服务器") + ": " + Fmt.host(settings.normalizedBaseURL),
            loc("项目") + ": " + "\(state.monitoredProjects.count)",
            loc("流水线") + ": " + "\(state.allVisiblePipelines.count)",
            "Bundle: " + AppInfo.bundleID,
            "Path: " + AppInfo.bundlePath
        ].joined(separator: "\n")
    }
}
