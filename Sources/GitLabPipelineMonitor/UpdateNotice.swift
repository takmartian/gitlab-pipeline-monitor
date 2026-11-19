import AppKit
import SwiftUI

// MARK: - 更新提示弹窗

/// 检测到新版本时弹出的窗口：展示更新内容，让用户选「立即更新」还是「忽略此版本」。
@MainActor
final class UpdateNoticeController {
    private static var window: NSWindow?

    /// 关掉窗口（点了「忽略」之后要收起来）
    static func close() {
        window?.orderOut(nil)
    }

    /// 复用同一个窗口：重复弹出会闪一下再换内容
    static func present(release: GitHubRelease,
                         currentVersion: String,
                         onUpdate: @escaping () -> Void,
                         onIgnore: @escaping () -> Void) {
        let view = UpdateNoticeView(
            version: release.version,
            currentVersion: currentVersion,
            notes: UpdateNotes.plain(release.body),
            onUpdate: onUpdate,
            onIgnore: onIgnore
        )
        let hosting = NSHostingController(rootView: view)

        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.contentViewController = hosting
        } else {
            // 先给一个确切尺寸再挂内容视图：用 contentViewController 直接建窗口时，
            // 视图的初始视口是 0，ScrollView 会把自己滚到内容末尾（打开就停在中间），实测过
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
            window.contentViewController = hosting
            window.title = loc("更新")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        window.setContentSize(NSSize(width: 460, height: 400))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 弹窗内容

struct UpdateNoticeView: View {
    let version: String
    let currentVersion: String
    let notes: String
    var onUpdate: () -> Void = {}
    var onIgnore: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(locf("有新版本 %@", version))
                        .font(.system(size: 14, weight: .bold))
                    Text(locf("当前版本 %@", currentVersion))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)

            Divider()

            ScrollView {
                Text(notes)
                    .font(.system(size: 11))
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button(loc("忽略此版本"), action: onIgnore)
                Button(loc("立即更新"), action: onUpdate)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 460, height: 400)
    }
}

// MARK: - 更新说明文本

enum UpdateNotes {
    /// release body 是 markdown，SwiftUI 的 Text 不渲染它，符号留着会很乱。
    /// 这里粗略清一遍：去掉井号标题、代码围栏、反引号、加粗号，列表换成中点。
    static func plain(_ body: String?) -> String {
        guard let body, !body.trimmed.isEmpty else { return loc("这个版本没有写更新说明。") }
        var lines: [String] = []
        var inFence = false
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if line.isEmpty {
                // 连续空行压成一个
                if lines.last?.isEmpty == false { lines.append("") }
                continue
            }
            var text = line
            while text.hasPrefix("#") {
                text = String(text.dropFirst()).trimmed
            }
            if text.hasPrefix("- ") || text.hasPrefix("* ") {
                text = "· " + String(text.dropFirst(2))
            }
            text = text.replacingOccurrences(of: "`", with: "")
            text = text.replacingOccurrences(of: "**", with: "")
            lines.append(text)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.isEmpty ? loc("这个版本没有写更新说明。") : lines.joined(separator: "\n")
    }
}
