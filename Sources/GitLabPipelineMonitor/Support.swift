import AppKit
import SwiftUI


// MARK: - 面板尺寸

/// 面板宽度在设置里选，高度直接拖底边调：这里定默认值和上下限
enum PanelMetrics {
    static let defaultHeight = 560
    static let minHeight = 320

    /// 最高不能超过屏幕可用高度：底边一旦拖出屏幕就再也抓不回来
    static func maxHeight(screen: NSScreen? = NSScreen.main) -> Int {
        let visible = screen?.visibleFrame.height ?? 1000
        return max(minHeight, Int(visible) - 12)
    }

    static func clamp(_ height: Int, screen: NSScreen? = NSScreen.main) -> Int {
        min(max(height, minHeight), maxHeight(screen: screen))
    }
}

// MARK: - 应用元信息

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.rexngsc.gitlab-pipeline-monitor" }
    static var name: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "GitLab Pipeline Monitor" }
    static var bundlePath: String { Bundle.main.bundlePath }
}

// MARK: - 通用格式化

enum Fmt {
    /// 相对时间（"3 分钟前" / "3 min ago"），跟随当前语言。
    static func relative(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    static func clock(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }

    /// 秒 -> "1h 12m" / "3m 12s" / "45s"
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let m = total / 60, s = total % 60
        if m < 60 { return s == 0 ? "\(m)m" : "\(m)m \(s)s" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }

    static func host(_ url: URL?) -> String {
        guard let host = url?.host else { return "—" }
        return url?.port.map { "\(host):\($0)" } ?? host
    }
}

// MARK: - 小工具

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 在浏览器里打开链接。
/// 直接拿裸字符串去 URL(string:) 是有坑的：残缺链接（比如 web_url 没取到时拼出的
/// "/pipelines"）也是合法 URL，但没有 scheme 和主机名，交给 LaunchServices 会被当成
/// 文件路径，弹出「应用程序无法打开。-50」。这里统一做三件事：
/// 补 scheme、用服务器地址补全相对路径、拒绝任何非 http(s) 的链接。
@MainActor
@discardableResult
func openURL(_ string: String?, base: URL? = nil) -> Bool {
    var raw = string?.trimmed ?? ""
    if raw.isEmpty, let base { raw = base.absoluteString }
    if raw.hasPrefix("/"), let base { raw = base.absoluteString + raw }
    guard !raw.isEmpty else { return false }
    if !raw.contains("://") { raw = "https://" + raw }

    guard let url = URL(string: raw),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          let host = url.host, !host.isEmpty
    else {
        NSLog("忽略无法打开的链接: \(string ?? "nil")")
        return false
    }
    return NSWorkspace.shared.open(url)
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
