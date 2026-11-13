import Foundation
import SwiftUI
import ServiceManagement

private enum Key {
    static let serverURL = "serverURL"
    static let authMode = "authMode"
    static let language = "language"
    static let refreshInterval = "refreshInterval"
    static let pipelinesPerProject = "pipelinesPerProject"
    static let onlyStarred = "onlyStarred"
    static let monitoredProjects = "monitoredProjects"
    static let showBadge = "showBadge"
    static let showFailureCount = "showFailureCount"
    static let notifyFailure = "notifyFailure"
    static let notifyRecovery = "notifyRecovery"
    static let refreshOnOpen = "refreshOnOpen"
    static let panelWidth = "panelWidth"
}

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// 令牌归属的存储账户（跟随服务器地址变化）
    private var tokenAccount: String = "default"
    /// 程序内部改写 token 时置真：切账户读回来的空值不是「用户清空令牌」，不该去删存储
    private var isProgrammaticToken = false

    @Published var serverURL: String {
        didSet {
            guard serverURL != oldValue else { return }
            defaults.set(serverURL, forKey: Key.serverURL)
            // 地址是逐字输入的：还没形成合法主机名时先别动令牌账户，
            // 否则每敲一个字符都会把内存里的令牌当成「该账户没有令牌」清空，面板会闪「未配置」
            guard let next = Self.strictAccount(for: serverURL), next != tokenAccount else { return }
            let current = token
            tokenAccount = next
            if let stored = TokenStore.password(account: next), !stored.trimmed.isEmpty {
                applyToken(stored)                       // 切到该实例自己的令牌
            } else if !current.trimmed.isEmpty {
                TokenStore.set(current, account: next)   // 当前令牌跟着新地址走，不丢
            }
        }
    }

    @Published var authMode: GitLabAuthMode {
        didSet { defaults.set(authMode.rawValue, forKey: Key.authMode) }
    }

    /// 明文只在内存里，落盘走加密文件
    @Published var token: String {
        didSet {
            guard token != oldValue, !isProgrammaticToken else { return }
            if token.isEmpty {
                TokenStore.remove(account: tokenAccount)
            } else {
                TokenStore.set(token, account: tokenAccount)
            }
        }
    }

    /// 程序内部赋值令牌（切换实例等），不触发落盘也不删条目
    private func applyToken(_ value: String) {
        isProgrammaticToken = true
        token = value
        isProgrammaticToken = false
    }

    @Published var language: AppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: Key.language)
            L10n.language = language
        }
    }

    /// 秒；0 = 关闭自动刷新
    @Published var refreshInterval: Int {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    @Published var pipelinesPerProject: Int {
        didSet { defaults.set(pipelinesPerProject, forKey: Key.pipelinesPerProject) }
    }

    @Published var onlyStarred: Bool {
        didSet { defaults.set(onlyStarred, forKey: Key.onlyStarred) }
    }

    @Published var monitoredProjectIDs: [Int] {
        didSet { defaults.set(monitoredProjectIDs, forKey: Key.monitoredProjects) }
    }

    @Published var showStatusBadge: Bool {
        didSet { defaults.set(showStatusBadge, forKey: Key.showBadge) }
    }

    @Published var showFailureCount: Bool {
        didSet { defaults.set(showFailureCount, forKey: Key.showFailureCount) }
    }

    @Published var notifyOnFailure: Bool {
        didSet { defaults.set(notifyOnFailure, forKey: Key.notifyFailure) }
    }

    @Published var notifyOnRecovery: Bool {
        didSet { defaults.set(notifyOnRecovery, forKey: Key.notifyRecovery) }
    }

    @Published var refreshOnOpen: Bool {
        didSet { defaults.set(refreshOnOpen, forKey: Key.refreshOnOpen) }
    }

    @Published var panelWidth: Int {
        didSet { defaults.set(panelWidth, forKey: Key.panelWidth) }
    }

    /// 计算属性：真值来自系统，写入即注册/取消登录项（用 objectWillChange 让开关立刻回弹）
    var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
            return false
        }
        set {
            guard #available(macOS 13.0, *), newValue != launchAtLogin else { return }
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("登录时启动设置失败: \(error.localizedDescription)")
            }
        }
    }

    static let refreshIntervals: [Int] = [0, 30, 60, 120, 300, 600]
    static let panelWidths: [Int] = [380, 420, 460, 520]

    static func refreshIntervalLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return loc("从不")
        case 30: return locf("每 %d 秒", 30)
        case 60: return loc("每分钟")
        case 120: return loc("每 2 分钟")
        case 300: return loc("每 5 分钟")
        case 600: return loc("每 10 分钟")
        default: return locf("每 %d 秒", seconds)
        }
    }

    private static func account(for rawURL: String) -> String {
        strictAccount(for: rawURL) ?? "default"
    }

    /// 只有像样的主机名才算账户：把令牌误粘进地址栏（glpat-xxx）或地址还没输完时返回 nil，
    /// 免得凭空多出一条垃圾条目，也免得来回改地址时把令牌清成空
    static func strictAccount(for rawURL: String) -> String? {
        guard let host = normalized(rawURL)?.host else { return nil }
        return (host.contains(".") || host.contains(":")) ? host : nil
    }

    /// 补全 scheme、去掉末尾斜杠和误填的 /api/v4；空串或没有主机名时返回 nil
    static func normalized(_ raw: String) -> URL? {
        var value = raw.trimmed
        if value.isEmpty { return nil }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        // 很多人会把 API 地址一起粘进来，这里自愈，免得 404
        while value.lowercased().hasSuffix("/api/v4") {
            value.removeLast("/api/v4".count)
            while value.hasSuffix("/") { value.removeLast() }
        }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var normalizedBaseURL: URL? { Self.normalized(serverURL) }

    /// 演示模式：不联网也能预览界面（--demo / --snapshot）
    var demoMode = false

    var isConfigured: Bool { demoMode || (normalizedBaseURL != nil && !token.trimmed.isEmpty) }

    var tokenAccountHost: String { tokenAccount }

    init() {
        let url = defaults.string(forKey: Key.serverURL) ?? ""
        serverURL = url
        authMode = GitLabAuthMode(rawValue: defaults.string(forKey: Key.authMode) ?? "") ?? .pat
        token = ""
        language = AppLanguage(rawValue: defaults.string(forKey: Key.language) ?? "") ?? .auto
        refreshInterval = defaults.object(forKey: Key.refreshInterval) as? Int ?? 120
        pipelinesPerProject = defaults.object(forKey: Key.pipelinesPerProject) as? Int ?? 5
        onlyStarred = defaults.object(forKey: Key.onlyStarred) as? Bool ?? true
        monitoredProjectIDs = (defaults.array(forKey: Key.monitoredProjects) as? [Int]) ?? []
        showStatusBadge = defaults.object(forKey: Key.showBadge) as? Bool ?? true
        showFailureCount = defaults.object(forKey: Key.showFailureCount) as? Bool ?? true
        notifyOnFailure = defaults.object(forKey: Key.notifyFailure) as? Bool ?? true
        notifyOnRecovery = defaults.object(forKey: Key.notifyRecovery) as? Bool ?? false
        refreshOnOpen = defaults.object(forKey: Key.refreshOnOpen) as? Bool ?? true
        panelWidth = defaults.integer(forKey: Key.panelWidth)
        if !Self.panelWidths.contains(panelWidth) { panelWidth = 420 }

        tokenAccount = Self.account(for: url)
        applyToken(TokenStore.password(account: tokenAccount) ?? "")
        L10n.language = language
    }
}
