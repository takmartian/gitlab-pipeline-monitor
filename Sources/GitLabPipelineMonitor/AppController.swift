import AppKit
import SwiftUI
import Combine

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    static let shared = AppController()

    let settings = AppSettings()
    private(set) lazy var state = AppState(settings: settings)
    /// 自研更新器：GitHub Release 就是更新源
    let updater = UpdateManager()

    private var menuBar: MenuBarController?
    private var settingsWindow: SettingsWindowController?
    private var savedInterval: Int = 120
    /// 截图用：设置-项目页搜索框的预填内容
    private var settingsProjectsQuery: String = ""

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
            size: NSSize(width: CGFloat(self.settings.panelWidth), height: CGFloat(self.settings.panelHeight)),
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
            view.environmentObject(self.state).environmentObject(self.settings).environmentObject(self.updater),
            size: NSSize(width: 600, height: 430),
            to: "/tmp/glpm-tab-\(name).png"
        )
        exit(0)
    }

    /// --resizetest：验证弹窗在已显示时能不能真的改变高度（打印窗口边框变化）
    private func runResizeTest() {
        settings.demoMode = true
        DemoData.apply(to: state)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            self.menuBar?.open()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                self.menuBar?.printPanelFrame("初始")
                let steps = [420, 680, 900, 560]
                for (index, height) in steps.enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index)) {
                        self.settings.panelHeight = height
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25 * Double(index) + 0.12) {
                        self.menuBar?.printPanelFrame("设为 \(height)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { exit(0) }
            }
        }
    }

    /// --capture <路径> [panel|settings]：弹出真实界面后抓屏
    private var capturePath: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--capture") else { return nil }
        return CommandLine.arguments.dropFirst(index + 1).first
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
            size: NSSize(width: CGFloat(settings.panelWidth), height: CGFloat(settings.panelHeight)),
            to: paths[0]
        )
        if paths.count > 1 {
            Snapshot.writeWindow(
                SettingsView(tabs: PassthroughSubject<SettingsTab, Never>())
                    .environmentObject(state)
                    .environmentObject(settings)
                    .environmentObject(updater),
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

        if CommandLine.arguments.contains("--urls") {
            runURLCheck()
            return
        }

        if CommandLine.arguments.contains("--openurl") {
            runOpenURLCheck()
            return
        }

        if CommandLine.arguments.contains("--updateprobe") {
            runUpdateProbe()
            return
        }

        if CommandLine.arguments.contains("--updateinstall") {
            runUpdateInstall()
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--starprobe") {
            let rest = Array(CommandLine.arguments.dropFirst(index + 1))
            runStarProbe(keyword: rest.first)
            return
        }

        Notifier.prepare(requestIfMissing: true)
        state.onIconNeedsUpdate = { [weak self] in self?.menuBar?.updateIcon() }
        menuBar = MenuBarController(state: state, settings: settings, updater: updater)
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

        if CommandLine.arguments.contains("--resizetest") {
            runResizeTest()
            return
        }

        if let path = capturePath {
            // 必须转成 Array：ArraySlice 保留原数组的索引，dropFirst 之后 startIndex 已经不是 0，
            // 直接 rest[1] 会越界 trap（count 是对的，下标是错的）
            let rest = Array(CommandLine.arguments.dropFirst(CommandLine.arguments.firstIndex(of: "--capture")! + 1))
            runCapture(to: path, what: rest.count > 1 ? rest[1] : "panel")
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
            scheduleUpdateCheck()
        }

        if let tab = settingsLaunchTab {
            showSettings(tab: tab)
        }
    }

    /// 启动后稍等再查更新：别跟首屏抢网络。顺手把上次更新留下的旧版本备份清掉
    private func scheduleUpdateCheck() {
        UpdatePaths.prepare()
        updater.cleanupPreviousVersion()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            Task { @MainActor in await self.updater.check() }
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

    // MARK: - 链接自检

    /// --openurl：真的走一遍界面用的 openURL()，把第一个星标项目的流水线页打开，
    /// 用来端到端验证「点浏览器图标能不能打开链接」
    private func runOpenURLCheck() {
        Task { @MainActor in
            guard let client = state.client() else { print("✗ 未配置或令牌不可用"); exit(1) }
            let base = settings.normalizedBaseURL
            guard let project = (try? await client.starredProjects())?.first else {
                print("✗ 没有星标项目")
                exit(1)
            }
            let target = project.pipelinesURL(base: base)
            print("准备打开 \(target)")
            let opened = openURL(target, base: base)
            print(opened ? "✓ 已交给浏览器打开" : "✗ openURL 拒绝了这个链接")
            // 空串、相对路径这类残缺链接不该再丢给 LaunchServices（那会弹「应用程序无法打开 -50」）
            print("空串 → \(openURL("", base: nil))（应为 false）")
            print("相对路径 /pipelines → \(openURL("/pipelines", base: nil))（应为 false）")
            print("缺 scheme gitlab.example.com/x → \(openURL("gitlab.example.com/x", base: nil))（应为 true）")
            exit(0)
        }
    }

    /// --urls：验证 web_url / updated_at 这类带下划线的字段是否真的解码出来了。
    /// 「点浏览器图标弹 -50」就是 web_url 为空、拼出 "/pipelines" 被当文件打开导致的。
    private func runURLCheck() {
        let base = settings.normalizedBaseURL
        print("服务器 \(base?.absoluteString ?? "无法解析")")
        Task { @MainActor in
            guard let client = state.client() else { print("✗ 未配置或令牌不可用"); exit(1) }
            let starred = (try? await client.starredProjects()) ?? []
            print("星标项目 \(starred.count)")
            for project in starred {
                print("· \(project.pathWithNamespace)")
                print("    web_url  \(project.webURL.isEmpty ? "«空»" : project.webURL)")
                print("    兜底     \(project.resolvedWebURL(base: base))")
                print("    流水线页 \(project.pipelinesURL(base: base))")
                print("    活动 \(project.lastActivityAt.map { Fmt.relative($0) } ?? "«nil»") · star=\(project.starCount) · 默认分支 \(project.defaultBranch ?? "«nil»")")
                let pipes = (try? await client.pipelines(projectID: project.id, limit: 2)) ?? []
                for item in pipes {
                    print("      #\(item.iid) \(item.status.rawValue) @\(item.ref) 更新 \(item.updatedAt.map { Fmt.relative($0) } ?? "«nil»")")
                    print("        列表     触发人 \(item.user?.username ?? "«nil»") · 耗时 \(Fmt.duration(item.duration)) · 覆盖率 \(item.covered ?? "«nil»")")
                    var enriched = item
                    if let detail = try? await client.pipelineDetail(projectID: project.id, pipelineID: item.id) {
                        enriched.mergeDetail(detail)
                    }
                    print("        补详情后 触发人 \(enriched.user?.username ?? "«nil»") · 耗时 \(Fmt.duration(enriched.duration)) · 覆盖率 \(enriched.covered ?? "«nil»")")
                    print("        链接 \(project.pipelineURL(item, base: base))")
                    if let first = pipes.first, item.id == first.id {
                        let jobs = (try? await client.jobs(projectID: project.id, pipelineID: item.id)) ?? []
                        for job in jobs.prefix(2) {
                            print("        作业 \(job.name)：web_url \(job.webURL ?? "«nil»") → \(job.resolvedWebURL(base: base, project: project))")
                        }
                    }
                }
            }
            if let user = try? await client.currentUser() {
                print("用户 web_url \(user.webURL ?? "«nil»")")
            }
            exit(0)
        }
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

    // MARK: - 打星诊断

    /// --starprobe [项目路径关键词]：把打星相关的请求逐个发一遍，打印状态码与服务器原话。
    /// 不带关键词时只列出服务器认为已打星的项目（不产生任何改动）。
    private func runStarProbe(keyword: String?) {
        Task { @MainActor in
            guard let client = state.client() else { print("✗ 未配置或令牌不可用"); exit(1) }
            let starred = (try? await client.starredProjects()) ?? []
            print("服务器认为已打星 \(starred.count) 个：")
            for item in starred { print("   id=\(item.id)  \(item.pathWithNamespace)  star_count=\(item.starCount)") }
            // 方法与路由探测：/version 只接受 GET，DELETE/POST 都该由 GitLab 回 405。
            // 如果 DELETE 拿到的是纯文本 404，说明请求被网关吃掉、根本没到 GitLab。
            let delProbe = await client.rawRequest("/version", method: "DELETE")
            print("DELETE /version → \(delProbe.status) \(String(delProbe.body.prefix(140)))")
            let postProbe = await client.rawRequest("/version", method: "POST")
            print("POST   /version → \(postProbe.status) \(String(postProbe.body.prefix(140)))")
            guard let keyword, !keyword.isEmpty else {
                print("（只读探测，未做任何改动；加项目路径关键词可试取消打星）")
                exit(0)
            }
            // 关键词可以是项目路径的一部分，也可以直接是项目 id（一个星都没打时只能这样试）
            let id: Int
            if let numeric = Int(keyword) {
                id = numeric
            } else if let found = starred.first(where: { $0.pathWithNamespace.localizedCaseInsensitiveContains(keyword) }) {
                id = found.id
            } else {
                print("✗ 已打星列表里没有包含「\(keyword)」的项目（也可以直接传项目 id）")
                exit(1)
            }
            let project = await client.rawRequest("/projects/\(id)")
            print("GET    /projects/\(id) → \(project.status) \(String(project.body.prefix(160)))")
            let del = await client.rawRequest("/projects/\(id)/star", method: "DELETE")
            print("DELETE /projects/\(id)/star → \(del.status) \(String(del.body.prefix(300)))")
            // 走真实代码路径：先确保是打星状态，再调 App 实际用的 client.unstar
            let re = await client.rawRequest("/projects/\(id)/star", method: "POST")
            print("POST   /projects/\(id)/star（先打回星）→ \(re.status)")
            do {
                _ = try await client.unstar(projectID: id)
                print("client.unstar(\(id)) → ✓ 成功（这就是面板/设置里点的那个调用）")
            } catch {
                let message = (error as? GitLabError)?.message ?? error.localizedDescription
                print("client.unstar(\(id)) → ✗ \(message)")
            }
            print("DELETE /projects/\(id)/star → \(del.status) \(String(del.body.prefix(300)))")
            let after = (try? await client.starredProjects()) ?? []
            print("取消后已打星 \(after.count) 个：\(after.map { $0.pathWithNamespace }.joined(separator: " , "))")
            exit(0)
        }
    }

    // MARK: - 更新诊断

    /// 诊断输出走 stderr：stdout 重定向到文件/管道时是全缓冲，进程不退出就看不到
    private func probeLog(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8) ?? Data())
    }

    /// --updateprobe：打印 GitHub Release 的最新版本、资产与校验摘要
    private func runUpdateProbe() {
        Task { @MainActor in
            await self.updater.check(force: true)
            probeLog("当前版本 \(self.updater.currentVersion)")
            if let release = self.updater.release {
                probeLog("远端最新 \(release.version)（tag \(release.tagName) · prerelease \(release.prerelease)）")
                probeLog("页面 \(release.htmlURL)")
                for asset in release.assets {
                    probeLog("  资产 \(asset.name) · \(asset.size) 字节 · digest \(asset.digest ?? "无")")
                }
                if let asset = release.preferredAsset {
                    probeLog("将下载 \(asset.browserDownloadURL)")
                }
            } else {
                probeLog("没拿到 release")
            }
            probeLog("有更新: \(self.updater.updateAvailable) · 最新 \(self.updater.latestVersion ?? "无")")
            if case .failed(let message) = self.updater.phase { probeLog("失败: \(message)") }
            exit(0)
        }
    }

    /// --updateinstall：查到新版本就直接装，用来端到端验证整条更新链路
    /// （下载 → 校验 → 解压 → 替换 → 重启）。会真的替换掉当前这个 App。
    private func runUpdateInstall() {
        NSLog("更新诊断：进入 runUpdateInstall")
        Task { @MainActor in
            NSLog("更新诊断：Task 已启动")
            await self.updater.check(force: true)
            NSLog("更新诊断：检查结束，有更新=%@", self.updater.updateAvailable ? "是" : "否")
            guard self.updater.updateAvailable else {
                probeLog("没有新版本可装（当前 \(self.updater.currentVersion)）")
                exit(1)
            }
            probeLog("准备安装 \(self.updater.latestVersion ?? "?")，当前是 \(self.updater.currentVersion)")
            await self.updater.install()
            // install() 末尾会退出 App；这里兜个底，别让进程挂着
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { exit(0) }
        }
    }

    // MARK: - 抓屏出图

    /// --capture <路径> [panel|settings]：以演示模式启动、弹出真实界面后抓屏。
    /// 比离屏渲染可靠：离屏那条路 NSHostingView 会按内容的理想尺寸撑宽，右侧内容会画到画布外。
    private func runCapture(to path: String, what: String) {
        settings.demoMode = true
        DemoData.apply(to: state)
        state.onIconNeedsUpdate?()
        menuBar?.updateIcon()
        // 截图会进公开仓库：地址栏换成示例地址，抓完在退出前原样写回，
        // 顺手删掉 didSet 顺手存进示例账户的那条令牌，别留下垃圾条目。
        // 只在「连接」页做这件事：改 serverURL 会触发防抖重置，把演示项目全清空。
        let originalURL = settings.serverURL
        let maskAddress = what == "settings"
        if maskAddress { settings.serverURL = "https://gitlab.example.com" }
        // 面板/设置窗口必须等应用完成启动后再开：在 applicationDidFinishLaunching 里同步开
        // 会直接崩（--demo 也是延迟开的，这里照做）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.activate(ignoringOtherApps: true)
            if what == "settings" {
                self.showSettings()
            } else if what == "projects" {
                self.settingsProjectsQuery = "crm"
                self.showSettings(tab: .projects)
            } else if what == "general" {
                self.showSettings(tab: .general)
            } else if what == "about" {
                self.showSettings(tab: .about)
            } else {
                self.menuBar?.open()
            }
        }
        // 再等窗口真正画出来才抓
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard let rect = Self.capturedWindowBounds(preferWide: what == "panel") else {
                print("✗ 找不到窗口")
                self.settings.serverURL = originalURL
                exit(1)
            }
            let region = "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
            let task = Process()
            task.launchPath = "/usr/sbin/screencapture"
            // -x 不出声，-o 不带阴影（阴影在窗口边界外，会被裁成半截）
            task.arguments = ["-x", "-o", "-R", region, path]
            task.launch()
            task.waitUntilExit()
            print(task.terminationStatus == 0 ? "✓ 已抓取 \(region) → \(path)" : "✗ screencapture 退出码 \(task.terminationStatus)")
            if maskAddress {
                TokenStore.remove(account: "gitlab.example.com")
                self.settings.serverURL = originalURL
            }
            exit(task.terminationStatus == 0 ? 0 : 1)
        }
    }

    /// 在自己的窗口里挑一个：面板约 420 宽，设置窗口更宽，菜单栏状态项很扁，按尺寸区分
    private static func capturedWindowBounds(preferWide: Bool) -> NSRect? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var candidates: [NSRect] = []
        for info in list {
            // 数值一律先按 Double/Int 取，再显式转：这些字典是 CFNumber，直接 as? CGFloat / as? pid_t 不可靠
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner == pid else { continue }
            guard let box = info[kCGWindowBounds as String] as? [String: Any],
                  let x = (box["X"] as? NSNumber)?.doubleValue, let y = (box["Y"] as? NSNumber)?.doubleValue,
                  let w = (box["Width"] as? NSNumber)?.doubleValue, let h = (box["Height"] as? NSNumber)?.doubleValue else { continue }
            let rect = NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w), height: CGFloat(h))
            guard w > 200, h > 200 else { continue }   // 排除扁长的菜单栏状态项
            candidates.append(rect)
        }
        guard !candidates.isEmpty else { return nil }
        if preferWide { return candidates.filter { $0.width < 500 }.max { $0.width * $0.height > $1.width * $1.height } ?? candidates.max { $0.width * $0.height > $1.width * $1.height } }
        return candidates.max { $0.width * $0.height > $1.width * $1.height }
    }

    // MARK: - 供界面调用

    func showSettings(tab: SettingsTab = .connection) {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(state: state, settings: settings, updater: updater,
                                                     projectsQuery: settingsProjectsQuery)
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
