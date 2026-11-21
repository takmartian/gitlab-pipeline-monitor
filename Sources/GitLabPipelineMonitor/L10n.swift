import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case auto, zh, en
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "跟随系统"
        case .zh: return "简体中文"
        case .en: return "English"
        }
    }
}

/// 轻量本地化：代码里写中文原文，英文环境下查表翻译，查不到就退回中文。
/// 新增文案时最坏情况只是英文下显示中文，不会出现 key 占位符。
enum L10n {
    static var language: AppLanguage = .auto

    static var resolved: AppLanguage {
        switch language {
        case .zh, .en: return language
        case .auto:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .zh : .en
        }
    }

    static var isEnglish: Bool { resolved == .en }

    static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_CN") }

    static func t(_ zh: String) -> String {
        guard isEnglish, let value = en[zh] else { return zh }
        return value
    }
}

@inline(__always) func loc(_ zh: String) -> String { L10n.t(zh) }

@inline(__always) func locf(_ zh: String, _ args: CVarArg...) -> String {
    String(format: L10n.t(zh), arguments: args)
}

private let en: [String: String] = [
    // 通用
    "刷新": "Refresh",
    "刷新中…": "Refreshing…",
    "设置": "Settings",
    "退出": "Quit",
    "取消": "Cancel",
    "关闭": "Close",
    "重试": "Retry",
    "确定": "OK",
    "复制分支名": "Copy Branch",
    "复制提交 SHA": "Copy Commit SHA",
    "搜索": "Search",
    "加载中…": "Loading…",
    "运行中": "Running",
    "全部": "All",
    "失败": "Failed",
    "成功": "Passed",
    "已取消": "Canceled",
    "其他": "Other",
    "未知": "Unknown",
    "未配置": "Not configured",
    "星标": "Starred",
    "项目": "Projects",
    "流水线": "Pipelines",
    "分支": "Branch",
    "提交": "Commit",
    "作者": "Author",
    "耗时": "Duration",
    "覆盖率": "Coverage",
    "阶段": "Stage",
    "作业": "Jobs",
    "详情": "Details",
    "打开 GitLab": "Open GitLab",
    "拖动底边调整高度，双击恢复默认": "Drag the bottom edge to resize · double-click to reset",

    // 更新
    "检查更新": "Check for Updates",
    "自动检查更新": "Check for updates automatically",
    "开启后每天自动检查一次，发现新版本会弹窗展示更新内容，由你决定立即更新还是忽略此版本。": "Checks once a day. When a new version is found, a window shows the release notes — update now or skip this version.",
    "已忽略 %@ 的更新提示": "Update prompt skipped for %@",
    "取消忽略": "Undo Skip",
    "忽略此版本": "Skip This Version",
    "立即更新": "Update Now",
    "这个版本没有写更新说明。": "This release has no notes.",
    "正在检查更新…": "Checking for Updates…",
    "更新到 %@": "Update to %@",
    "更新": "Updates",
    "有新版本 %@": "New version %@",
    "当前版本 %@": "Current version %@",
    "已是最新版本": "You're up to date",
    "检查更新失败": "Could not check for updates",
    "正在下载更新… %d%%": "Downloading update… %d%%",
    "正在安装更新…": "Installing update…",
    "即将退出并安装更新，应用会自动重新启动。": "The app will quit to install the update, then reopen automatically.",
    "更新源：GitHub Release": "Update source: GitHub Release",
    "下载地址无效": "Invalid download URL",
    "无法连接 GitHub（可能被网络或代理挡住）": "Cannot reach GitHub (your network or proxy may be blocking it)",
    "GitHub 接口访问过于频繁，稍后再试": "GitHub rate limit reached — try again later",
    "下载校验失败，已放弃更新": "Download verification failed; update aborted",
    "安装包里没找到 App，已放弃更新": "No app found in the archive; update aborted",

    // 面板
    "未配置 GitLab 连接": "GitLab is not configured",
    "填写服务器地址和访问令牌后，这里会显示你打星项目的流水线。": "Add your server address and access token to see pipelines of your starred projects.",
    "开始配置": "Start setup",
    "没有可监控的项目": "No projects to monitor",
    "在设置里勾选要监控的项目，或开启「仅监控星标项目」。": "Pick projects in Settings, or turn on “Starred projects only”.",
    "所有流水线都通过了": "All pipelines are passing",
    "没有符合筛选条件的流水线": "No pipelines match the filter",
    "连接失败": "Connection failed",
    "重新加载": "Reload",
    "暂无流水线记录": "No pipeline records yet",
    "更新于 %@": "Updated %@",
    "共 %d 个项目 · %d 条流水线": "%d projects · %d pipelines",
    "显示 %d / %d 条流水线": "Showing %d of %d pipelines",
    "运行新流水线": "Run pipeline",
    "在项目页打开": "Open in GitLab",
    "该项目的流水线加载失败": "Failed to load pipelines for this project",

    // 流水线状态
    "已创建": "Created",
    "等待资源": "Waiting for resource",
    "准备中": "Preparing",
    "排队中": "Pending",
    "已通过": "Passed",
    "已失败": "Failed",
    "已跳过": "Skipped",
    "手动": "Manual",
    "已计划": "Scheduled",
    "已阻塞": "Blocked",
    "未开始": "Not started",

    // 详情
    "流水线详情": "Pipeline details",
    "提交信息": "Commit message",
    "触发方式": "Triggered by",
    "开始时间": "Started",
    "结束时间": "Finished",
    "重跑流水线": "Retry pipeline",
    "停止流水线": "Cancel pipeline",
    "打开流水线页面": "Open pipeline page",
    "查看作业日志": "View job log",
    "重跑作业": "Retry job",
    "停止作业": "Cancel job",
    "允许失败": "Allowed to fail",
    "无作业": "No jobs",
    "作业加载失败": "Failed to load jobs",

    // 运行流水线
    "选择分支或标签": "Choose a branch or tag",
    "运行": "Run",
    "默认分支": "Default branch",
    "没有可用的分支": "No branches available",
    "流水线已创建": "Pipeline created",

    // 设置 - 连接
    "连接": "Connection",
    "服务器地址": "Server address",
    "例如 https://gitlab.example.com": "e.g. https://gitlab.example.com",
    "令牌类型": "Token type",
    "个人访问令牌 (PRIVATE-TOKEN)": "Personal access token (PRIVATE-TOKEN)",
    "OAuth 令牌 (Bearer)": "OAuth token (Bearer)",
    "访问令牌": "Access token",
    "粘贴令牌": "Paste your token",
    "令牌在本机加密保存（AES-GCM，密钥来自这台 Mac 和你的登录账户），不会写进配置文件。": "The token is encrypted on this Mac (AES-GCM, key derived from this machine and your account), never stored in a config file.",
    "测试连接": "Test connection",
    "正在测试…": "Testing…",
    "连接成功": "Connected",
    "令牌需要 read_api 权限；若还要读取未加入的项目，请加上 read_user。": "The token needs the read_api scope; add read_user to see projects you have not joined.",
    "创建令牌": "Create a token",
    "服务器": "Server",
    "GitLab 版本": "GitLab version",
    "登录用户": "Signed in as",

    // 设置 - 项目
    "仅监控星标项目": "Starred projects only",
    "手动选择要监控的项目": "Choose projects manually",
    "全选": "Select all",
    "清空": "Clear",
    "每个项目显示的流水线数": "Pipelines per project",
    "重新拉取项目列表": "Reload project list",
    "开启后只监控你打过星的项目；关闭后可在下方手动勾选。": "When on, only starred projects are monitored. When off, pick them below.",
    "没有星标项目": "No starred projects",
    "先在上面填好地址和令牌，然后重新拉取项目列表。": "Fill in the address and token above, then reload the project list.",
    "已加载 %d 个星标项目、%d 个参与项目": "%d starred and %d member projects loaded",
    "已选择 %d 个项目": "%d projects selected",

    // 设置 - 通用
    "通用": "General",
    "语言": "Language",
    "从不": "Never",
    "打开面板时自动刷新": "Refresh when opening the panel",
    "菜单栏图标显示状态": "Show status on the menu bar icon",
    "显示失败数量": "Show failing count",
    "流水线失败时通知": "Notify when a pipeline fails",
    "流水线恢复时通知": "Notify when a pipeline recovers",
    "登录时启动": "Launch at login",
    "自动刷新": "Auto refresh",
    "每 %d 秒": "Every %d seconds",
    "每分钟": "Every minute",
    "每 2 分钟": "Every 2 minutes",
    "每 5 分钟": "Every 5 minutes",
    "每 10 分钟": "Every 10 minutes",
    "系统未授权通知，请在「系统设置 → 通知」中开启。": "Notifications are not authorized. Enable them in System Settings → Notifications.",

    // 设置 - 关于
    "关于": "About",
    "原生 SwiftUI + AppKit 菜单栏应用，无 Electron、无外部依赖。": "Native SwiftUI + AppKit menu bar app. No Electron, no dependencies.",
    "构建位置": "Built at",
    "复制诊断信息": "Copy diagnostics",
    "在 Finder 中显示": "Show in Finder",

    // 通知
    "流水线失败": "Pipeline failed",
    "流水线已恢复": "Pipeline recovered",

    // 错误
    "未配置服务器地址或令牌": "Server address or token is not configured",
    "服务器地址无效，请填写形如 https://gitlab.example.com 的地址": "Invalid server address. Use a form like https://gitlab.example.com",
    "服务器返回的是网页而不是 API，请检查地址是否指向 GitLab 根地址": "The server returned a web page instead of API data. Check that the address points at your GitLab root URL",
    "无法连接服务器，请检查地址、网络或 VPN": "Cannot reach the server. Check the address, network or VPN",
    "令牌无效或已过期（401）": "Token is invalid or expired (401)",
    "没有权限（403）": "Permission denied (403)",
    "项目不存在或已被删除（404）": "Project not found or deleted (404)",
    "请求过于频繁（429），请加大刷新间隔": "Too many requests (429). Increase the refresh interval",
    "数据解析失败，可能不是 GitLab 服务器": "Failed to parse the response — this may not be a GitLab server",
    "请求已取消": "Request canceled",

    // 打星与项目列表
    "打星": "Star",
    "取消打星": "Unstar",
    "监控中": "Monitored",
    "参与": "Member",
    "正在加载参与项目…": "Loading member projects…",
    "还没有项目": "No projects yet",
    "先在「连接」里填好地址和令牌，再点「重新拉取项目列表」；列表出来后点行首的星标就能打星。": "Fill in the address and token under Connection, then reload the project list. Click the star at the start of a row to star a project.",
    "每 %d 条": "%d per project",
    "地址": "Address",
    "隐藏": "Hide",
    "显示": "Show",
    "改动即时生效，无需保存。": "Changes apply immediately — no save needed.",

    // 菜单与快捷键
    "撤销": "Undo",
    "重做": "Redo",
    "剪切": "Cut",
    "拷贝": "Copy",
    "粘贴": "Paste",

    // 杂项
    "项目 / 分支": "project / branch",
    "试试切换筛选或清空搜索。": "Try another filter or clear the search.",
    "归档": "Archived",
    "默认": "default",
    "服务器错误": "Server error"
]
