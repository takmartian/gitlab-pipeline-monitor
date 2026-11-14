import AppKit
import SwiftUI
import Combine

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    let settings = AppSettings()
    private(set) lazy var state = AppState(settings: settings)

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var savedInterval: Int = 120

    /// --demo / GLPM_DEMO=1：用假数据预览界面，不联网
    var isDemoMode: Bool {
        CommandLine.arguments.contains("--demo") || (ProcessInfo.processInfo.environment["GLPM_DEMO"] == "1")
    }


    /// --selftest <地址> [令牌]：命令行连通性自检，打印到 stdout 后退出
    private var selftestArgs: (url: String, token: String?)? {
        guard let index = CommandLine.arguments.firstIndex(of: "--selftest") else { return nil }
        let rest = Array(CommandLine.arguments.dropFirst(index + 1))
        guard let url = rest.first else { return nil }
        return (url, rest.count > 1 ? rest[1] : nil)
    }

    private func runSelfTest(url raw: String, token: String?) {
        guard let base = AppSettings.normalized(raw) else {
            print("✗ 地址无效: \(raw)")
            exit(1)
        }
        // 不传令牌时用已保存的令牌（避免把令牌敲在命令行里）
        let effective = (token?.isEmpty == false ? token : settings.token.trimmed) ?? ""
        let client = GitLabClient(baseURL: base, token: effective, authMode: settings.authMode)
        print("→ \(base.absoluteString)/api/v4")
        Task {
            do {
                let user = try await client.currentUser()
                print("✓ 用户: \(user.name) @\(user.username)")
                if let version = try? await client.version() {
                    print("✓ GitLab 版本: \(version.version ?? "?")")
                }
                let starred = try await client.starredProjects()
                print("✓ 星标项目: \(starred.count)")
                let member = (try? await client.memberProjects()) ?? []
                print("✓ 参与项目: \(member.count)")
                for project in starred.prefix(3) {
                    let pipes = (try? await client.pipelines(projectID: project.id, limit: 3)) ?? []
                    let summary = pipes.map { "#\($0.iid) \($0.status.rawValue)@\($0.ref)" }.joined(separator: " | ")
                    print("  · \(project.pathWithNamespace): \(summary.isEmpty ? "无流水线" : summary)")
                }
                exit(0)
            } catch {
                let message = (error as? GitLabError)?.message ?? error.localizedDescription
                print("✗ \(message)")
                if let detail = (error as? GitLabError)?.detail { print("  detail: \(detail)") }
                exit(2)
            }
        }
    }

    /// --snaptab <标签名>：单独渲染某个设置标签页
    private var snapshotTab: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snaptab") else { return nil }
        return CommandLine.arguments.dropFirst(index + 1).first
    }

    /// --snapdetail：渲染流水线详情页
    private var snapshotDetail: Bool { CommandLine.arguments.contains("--snapdetail") }

    private func renderDetailSnapshot() {
        guard let project = state.monitoredProjects.first,
              let pipeline = (state.pipelines[project.id] ?? []).first else { exit(1) }
        // 预填演示作业与提交：离屏抓取是同步的，等不到 .task 的异步结果
        Snapshot.writeWindow(
            PipelineDetailView(project: project, pipeline: pipeline, onBack: {},
                               initialJobs: DemoData.jobs(for: pipeline, project: project),
                               initialCommit: DemoData.commit(for: pipeline))
                .environmentObject(self.state)
                .environmentObject(self.settings),
            size: NSSize(width: CGFloat(self.settings.panelWidth), height: 560),
            to: "/tmp/glpm-detail.png"
        )
        exit(0)
    }

    private func renderTabSnapshot(_ name: String) {
        let view: AnyView
        switch name {
        case "projects": view = AnyView(ProjectsTab())
        case "general": view = AnyView(GeneralTab())
        case "about": view = AnyView(AboutTab())
        default: view = AnyView(ConnectionTab())
        }
        Snapshot.writeWindow(
            view.environmentObject(self.state).environmentObject(self.settings),
            size: NSSize(width: 600, height: 430),
            to: "/tmp/glpm-tab-\(name).png"
        )
        exit(0)
    }

    /// --snapshot <面板.png> <设置.png>：离屏渲染界面后退出
    private var snapshotPaths: [String]? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot") else { return nil }
        let paths = Array(CommandLine.arguments.dropFirst(index + 1).prefix(2))
        return paths.isEmpty ? nil : paths
    }

    private func renderSnapshots(_ paths: [String]) {
        Snapshot.menuBarPreview(status: state.aggregate, count: state.failingCount,
                                dark: false, to: "/tmp/glpm-menubar-light.png")
        Snapshot.menuBarPreview(status: state.aggregate, count: state.failingCount,
                                dark: true, to: "/tmp/glpm-menubar-dark.png")
        Snapshot.writeWindow(
            PanelView().environmentObject(state).environmentObject(settings),
            size: NSSize(width: CGFloat(settings.panelWidth), height: 560),
            to: paths[0]
        )
        if paths.count > 1 {
            Snapshot.writeWindow(
                SettingsView(tabs: PassthroughSubject<SettingsTab, Never>())
                    .environmentObject(state)
                    .environmentObject(settings),
                size: NSSize(width: 600, height: 470),
                to: paths[1]
            )
        }
        // 各设置标签页用 --snaptab 单独渲染（同一进程里连渲多个会触发 SwiftUI 断言）
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        if CommandLine.arguments.contains("--tokencheck") {
            runTokenCheck()
            return
        }

        if CommandLine.arguments.contains("--diag") {
            runDiagnostics()
            return
        }

        Notifier.prepare(requestIfMissing: true)
        state.onIconNeedsUpdate = { [weak self] in self?.menuBar?.updateIcon() }
        menuBar = MenuBarController(state: state, settings: settings)
        savedInterval = settings.refreshInterval > 0 ? settings.refreshInterval : 120

        if isDemoMode || snapshotPaths != nil {
            settings.demoMode = true
        }

        if let test = selftestArgs {
            runSelfTest(url: test.url, token: test.token)
            return
        }

        if let name = snapshotTab {
            settings.demoMode = true
            DemoData.apply(to: state)
            renderTabSnapshot(name)
            return
        }

        if snapshotDetail {
            settings.demoMode = true
            DemoData.apply(to: state)
            renderDetailSnapshot()
            return
        }

        if let paths = snapshotPaths {
            DemoData.apply(to: state)
            state.onIconNeedsUpdate?()
            menuBar?.updateIcon()
            renderSnapshots(paths)
            return
        }

        if isDemoMode {
            DemoData.apply(to: state)
            state.onIconNeedsUpdate?()
            menuBar?.updateIcon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.menuBar?.open()
            }
        } else {
            state.bootstrap()
        }

        if let tab = settingsLaunchTab {
            showSettings(tab: tab)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// 没有 Dock 图标，重新「打开」时把面板弹出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { menuBar?.open() }
        return true
    }

    // MARK: - 主菜单

    /// accessory 应用没有可见菜单栏，但 ⌘V / ⌘C / ⌘X / ⌘A 这类键位必须由主菜单派发到
    /// 第一响应者，否则地址和令牌输入框里粘贴会完全没反应。
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        let settingsItem = appMenu.addItem(withTitle: loc("设置"), action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: loc("退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: loc("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: loc("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: loc("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: loc("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: loc("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: loc("全选"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let refresh = viewMenu.addItem(withTitle: loc("刷新"), action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: loc("关闭"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettingsFromMenu() { showSettings() }

    @objc private func refreshFromMenu() { state.refresh(force: true) }

    // MARK: - 令牌自检

    /// --tokencheck：检查加密令牌文件（只报状态，不打印令牌本身）
    private func runTokenCheck() {
        let current = settings.tokenAccountHost
        print("文件 \(TokenStore.fileURL.path) · 权限 \(TokenStore.filePermissions()) · 机器指纹 \(TokenStore.seedKind())")
        let accounts = TokenStore.accounts()
        print("已存放账户: \(accounts.isEmpty ? "无" : accounts.joined(separator: ", "))")
        for acct in accounts {
            print("· \(acct) → \(TokenStore.decryptable(account: acct))")
        }
        print("当前账户 \(current) → \(TokenStore.decryptable(account: current))")
        let probe = "rex-probe-\(Int(Date().timeIntervalSince1970))"
        let wrote = TokenStore.set("roundtrip-value", account: probe)
        let read = TokenStore.decryptable(account: probe)
        let removed = TokenStore.remove(account: probe)
        print("往返自检 set: \(wrote) · read: \(read) · remove: \(removed)")
        let legacy = TokenStore.legacyAccounts()
        print("钥匙串残留: \(legacy.isEmpty ? "无" : legacy.joined(separator: ", "))")
        exit(0)
    }

    // MARK: - 连接诊断

    /// --diag：打印配置、令牌账户与一次真实拉取的结果（不打印令牌本身）
    private func runDiagnostics() {
        let token = settings.token.trimmed
        let accounts = TokenStore.accounts()
        print("地址 \(settings.serverURL) → \(settings.normalizedBaseURL?.absoluteString ?? "无法解析")")
        print("令牌账户 \(settings.tokenAccountHost) · 令牌长度 \(token.count) · isConfigured \(settings.isConfigured)")
        print("加密文件权限 \(TokenStore.filePermissions()) · 机器指纹 \(TokenStore.seedKind()) · 已存放账户 \(accounts.isEmpty ? "无" : accounts.joined(separator: ", "))")
        Task { @MainActor in
            switch await state.testConnection() {
            case .success(let info):
                print("连接 ✓ 用户 \(info.user.name) @\(info.user.username) · GitLab \(info.version ?? "?") · 星标 \(info.starredCount) · 参与 \(info.memberCount)")
            case .failure(let error):
                print("连接 ✗ \((error as? GitLabError)?.message ?? error.localizedDescription)")
            }
            state.resetAndRefresh()
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            print("刷新后：starred \(state.starredProjects.count) · member \(state.memberProjects.count) · 监控 \(state.monitoredProjects.count) · 流水线 \(state.allVisiblePipelines.count)")
            for project in state.monitoredProjects {
                print("  · \(project.pathWithNamespace) id=\(project.id) 条数=\((state.pipelines[project.id] ?? []).count)")
            }
            for (id, message) in state.projectErrors {
                print("  ✗ 项目 \(id)：\(message)")
            }
            print("onlyStarred \(settings.onlyStarred) · 勾选数 \(settings.monitoredProjectIDs.count)")
            state.ensureMemberProjects()
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            print("补拉参与项目后：member \(state.memberProjects.count) · 可用 \(state.availableProjects.count)")
            print("顶栏账号 \(state.user.map { "\($0.name) @\($0.username)" } ?? "nil")")
            if let error = state.fatalErrorMessage { print("错误 \(error)") } else { print("无致命错误") }
            exit(0)
        }
    }

    // MARK: - 供界面调用

    func showSettings(tab: SettingsTab = .connection) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(state: state, settings: settings)
        }
        settingsWindow?.select(tab)
        settingsWindow?.show()
    }

    func toggleAutoRefresh() {
        if settings.refreshInterval > 0 {
            savedInterval = settings.refreshInterval
            settings.refreshInterval = 0
        } else {
            settings.refreshInterval = savedInterval > 0 ? savedInterval : 120
        }
    }

    /// --settings [标签名]：启动即打开设置窗口，可选直接停在某个标签页
    var settingsLaunchTab: SettingsTab? {
        guard let index = CommandLine.arguments.firstIndex(of: "--settings") else { return nil }
        switch CommandLine.arguments.dropFirst(index + 1).first {
        case "projects": return .projects
        case "general": return .general
        case "about": return .about
        default: return .connection
        }
    }

    func openPanel() { menuBar?.open() }

    func closePanel() { menuBar?.close() }
}
