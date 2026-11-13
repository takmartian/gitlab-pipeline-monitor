import AppKit
import SwiftUI

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

@MainActor
func openURL(_ string: String?) {
    guard let string, let url = URL(string: string) else { return }
    NSWorkspace.shared.open(url)
}

@MainActor
func copyToPasteboard(_ string: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(string, forType: .string)
}
