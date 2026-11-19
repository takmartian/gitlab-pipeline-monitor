import AppKit
import Foundation
import Combine
import CryptoKit

// MARK: - 版本号

/// 版本号比较：按数字分段比，"1.1.10" 要比 "1.1.9" 新
enum AppVersion {
    static func components(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text.split(separator: ".").map { part in
            // 只取开头的数字："1.2.3-beta" → 3
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate)
        let b = components(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// "v1.1.3" → "1.1.3"
    static func normalized(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }
}

// MARK: - GitHub Release

/// 只取更新用得到的字段
struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let size: Int
        let browserDownloadURL: String
        /// GitHub 现在会给出 sha256 摘要（"sha256:…"），用来校验下载完整性
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    let tagName: String
    let htmlURL: String
    let body: String?
    let prerelease: Bool
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body, prerelease, assets
    }

    var version: String { AppVersion.normalized(tagName) }

    /// 优先用 zip：解压就是 .app，不用挂载 dmg
    var preferredAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".zip") } ?? assets.first
    }
}

// MARK: - 更新器

/// 自研的轻量更新器：GitHub Release 就是更新源，不需要额外托管任何东西。
///
/// 流程：查 Releases API → 比版本 → 下载 zip → 用服务端给的 sha256 校验 →
/// 解压 → 起一个独立 helper 进程（等本进程退出后）→ 备份旧版本 → 装新的 → 去隔离属性 → 重新启动。
@MainActor
final class UpdateManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case installing
        case failed(String)
        case upToDate

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// 有新版本时的最新版本号
    @Published private(set) var latestVersion: String?
    @Published private(set) var release: GitHubRelease?

    private let repo = "takmartian/gitlab-pipeline-monitor"
    private let settings: AppSettings
    private var session: URLSession!
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    /// 本次运行已经提示过的版本：同一个版本不反复弹窗
    private var notifiedVersion: String?

    private enum Key {
        static let lastCheck = "update.lastCheck"
    }

    init(settings: AppSettings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        // 资源超时给足：release 资产实测要 20~50 秒（国内直连 GitHub 慢）
        config.timeoutIntervalForResource = 300
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            // GitHub API 强制要求 User-Agent
            "User-Agent": "GitLabPipelineMonitor/\(AppInfo.version)",
            "Accept": "application/vnd.github+json"
        ]
        session = URLSession(configuration: config)

        // 每 6 小时看一眼；真正的请求由 24 小时缓存把住，不会碰限流
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 刚把开关打开就顺手查一次，不用等下一个 6 小时周期
        settings.$autoUpdateEnabled
            .removeDuplicates().dropFirst()
            .sink { [weak self] enabled in
                guard enabled else { return }
                Task { @MainActor in await self?.check() }
            }
            .store(in: &cancellables)
    }

    var currentVersion: String { AppInfo.version }
    var updateAvailable: Bool { latestVersion != nil }

    // MARK: - 检查

    /// 检查更新。自动检查一天最多一次（GitHub 匿名 API 每 IP 每小时 60 次）
    func check(force: Bool = false) async {
        NSLog("更新：进入检查 force=%@", force ? "是" : "否")
        guard phase != .checking else { return }
        // 自动检查受「通用 - 自动更新」开关控制；手动检查（force）不受影响
        if !force, !settings.autoUpdateEnabled { return }
        if !force {
            let last = UserDefaults.standard.object(forKey: Key.lastCheck) as? Date
            if let last, Date().timeIntervalSince(last) < 24 * 3600 { return }
        }
        phase = .checking
        do {
            let latest = try await fetchLatestRelease()
            NSLog("更新：拿到 release %@", latest.version)
            release = latest
            UserDefaults.standard.set(Date(), forKey: Key.lastCheck)
            if AppVersion.isNewer(latest.version, than: currentVersion) {
                latestVersion = latest.version
                phase = .idle
                handleUpdateFound(latest.version, automatic: !force)
            } else {
                latestVersion = nil
                phase = .upToDate
            }
        } catch {
            // 自动检查失败不打扰用户；手动检查才报错
            phase = force ? .failed(Self.describe(error)) : .idle
        }
    }

    private func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitLabPipelineMonitor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network("") }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw UpdateError.rateLimited
        }
        guard http.statusCode == 200 else { throw UpdateError.http(http.statusCode) }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    // MARK: - 安装

    /// 手动检查完给个明确反馈（自动检查不打扰）
    func presentCheckResult() {
        switch phase {
        case .upToDate:
            let alert = NSAlert()
            alert.messageText = loc("已是最新版本")
            alert.informativeText = locf("当前版本 %@", currentVersion)
            alert.addButton(withTitle: loc("确定"))
            NSApp.activate()
            alert.runModal()
        case .failed(let message):
            let alert = NSAlert()
            alert.messageText = loc("检查更新失败")
            alert.informativeText = message
            alert.addButton(withTitle: loc("确定"))
            NSApp.activate()
            alert.runModal()
        default:
            // 有新版本：也弹同一个窗口，把更新内容给用户看
            presentUpdateNotice()
        }
    }

    /// 发现新版本时的处理：自动检查才受「忽略此版本」影响，
    /// 手动检查是用户主动问的，一律把内容摆出来让他自己决定。
    private func handleUpdateFound(_ version: String, automatic: Bool) {
        if automatic {
            if settings.ignoredUpdateVersion == version { return }   // 用户说过忽略
            if notifiedVersion == version { return }                   // 本次运行已经提示过
        }
        notifiedVersion = version
        presentUpdateNotice()
    }

    /// 弹更新窗口：展示更新内容，让用户选「立即更新」还是「忽略此版本」
    func presentUpdateNotice() {
        guard let release else { return }
        UpdateNoticeController.present(release: release, currentVersion: currentVersion) { [weak self] in
            UpdateNoticeController.close()
            Task { @MainActor in await self?.install() }
        } onIgnore: { [weak self] in
            UpdateNoticeController.close()
            guard let self else { return }
            self.settings.ignoredUpdateVersion = release.version
            NSLog("更新：用户忽略了 %@", release.version)
        }
    }

    func install() async {
        guard let release, let asset = release.preferredAsset else { return }
        guard !phase.isBusy else { return }
        phase = .downloading

        do {
            let work = UpdatePaths.workDirectory
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let zipURL = work.appendingPathComponent("update.zip")
            try await download(asset: asset, to: zipURL)
            NSLog("更新：下载完成 %@", zipURL.path)

            // 校验：用服务端给的 sha256（GitHub 的 release 资产自带 digest）
            if let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") {
                let expected = String(digest.dropFirst(7)).lowercased()
                let actual = try Self.sha256(of: zipURL)
                NSLog("更新：校验 sha256 %@", actual == expected ? "通过" : "不匹配")
                guard actual == expected else { throw UpdateError.checksum }
            }

            // 解压：ditto 比 unzip 稳（zip 里的中文名和 AppleDouble 由它处理）
            let extracted = work.appendingPathComponent("extracted")
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            let status = try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extracted.path])
            NSLog("更新：解压退出码 %d", status)

            // 找到新的 .app
            let newApp = try findApp(in: extracted)
            NSLog("更新：新版本在 %@", newApp.path)
            let script = try writeHelper(newApp: newApp)
            phase = .installing

            // 先看能不能直接写：/Applications 对 admin 组可写，通常不用密码
            let needsAdmin = !Self.canWrite(directory: URL(fileURLWithPath: AppInfo.bundlePath).deletingLastPathComponent())
            NSLog("更新：需要管理员权限？%@", needsAdmin ? "是" : "否")
            try launchHelper(script: script, newApp: newApp, needsAdmin: needsAdmin)

            // helper 会等本进程退出后再替换，交给它接手
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            NSLog("更新失败：%@", Self.describe(error))
            phase = .failed(Self.describe(error))
        }
    }

    private func download(asset: GitHubRelease.Asset, to destination: URL) async throws {
        guard let url = URL(string: asset.browserDownloadURL) else { throw UpdateError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("GitLabPipelineMonitor/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")

        // 这里**不能**传自定义 delegate：异步下载 API 一旦给了 delegate，
        // 文件就交给 delegate 的 didFinishDownloadingTo，async 的 continuation 没人唤醒，
        // download(for:delegate:) 会一直挂着（实测卡死）。
        // 包只有 1MB，不要进度条了。
        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    private func findApp(in directory: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        // zip 里是 "GitLab Pipeline Monitor/GitLab Pipeline Monitor.app"，可能多一层目录
        if let direct = items.first(where: { $0.pathExtension == "app" }) { return direct }
        for item in items {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let inner = try FileManager.default.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)
            if let found = inner.first(where: { $0.pathExtension == "app" }) { return found }
        }
        throw UpdateError.noAppInArchive
    }

    /// 写安装脚本：等旧进程退出 → 备份 → 装新的 → 去隔离属性 → 重新启动
    private func writeHelper(newApp: URL) throws -> URL {
        let scriptURL = UpdatePaths.helperScript
        let script = Self.helperScript(
            appPath: AppInfo.bundlePath,
            newApp: newApp.path,
            backup: UpdatePaths.previousApp.path,
            log: UpdatePaths.logFile.path
        )
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// 启动 helper。脚本要 4 个参数（目标路径 / 新版本 / 备份 / 日志），
    /// 少传一个它就会在 set -u 下第一行直接退出，什么都不干。
    private func launchHelper(script: URL, newApp: URL, needsAdmin: Bool) throws {
        let paths = [script.path, AppInfo.bundlePath, newApp.path,
                     UpdatePaths.previousApp.path, UpdatePaths.logFile.path]
        if needsAdmin {
            // 需要管理员权限：走 osascript 弹一次系统授权
            let command = "/bin/bash " + paths.map(Self.shellQuote).joined(separator: " ")
            // AppleScript 字符串里反斜杠要先转义：路径里有单引号时 shellQuote 会产出 '\''，
            // 不转义的话 AppleScript 直接报语法错（实测）
            var escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", appleScript]
            try process.run()
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = paths
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }
    }

    /// shell 单引号转义：路径里有空格/引号时不加引号会被拆成好几个参数
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 新版本起来之后清掉旧版本备份
    func cleanupPreviousVersion() {
        guard FileManager.default.fileExists(atPath: UpdatePaths.previousApp.path) else { return }
        try? FileManager.default.removeItem(at: UpdatePaths.previousApp.deletingLastPathComponent())
    }

    // MARK: - 小工具

    private static func canWrite(directory: URL) -> Bool {
        let probe = directory.appendingPathComponent(".glpm-write-test-\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdateError { return error.message }
        return error.localizedDescription
    }

    /// 安装脚本内容。参数：目标路径、新版本路径、备份路径、日志路径
    static func helperScript(appPath: String, newApp: String, backup: String, log: String) -> String {
        """
        #!/bin/bash
        # 由 App 生成：等旧进程退出 → 备份旧版本 → 装新版本 → 去隔离属性 → 重新启动
        set -uo pipefail
        APP_PATH="$1"; NEW_APP="$2"; BACKUP="$3"; LOG="$4"

        log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null; }

        log "开始更新 → $APP_PATH"

        # 1) 等旧进程退出（最多 15 秒）
        for _ in $(seq 1 75); do
          pgrep -x "GitLabPipelineMonitor" >/dev/null 2>&1 || break
          sleep 0.2
        done
        if pgrep -x "GitLabPipelineMonitor" >/dev/null 2>&1; then
          log "旧进程没退，强制结束"
          pkill -x "GitLabPipelineMonitor" 2>/dev/null || true
          sleep 1
        fi

        # 2) 旧版本挪到备份位置（同盘 rename，秒级；备份放缓存目录，不留在 /Applications）
        if [ -d "$APP_PATH" ]; then
          mkdir -p "$(dirname "$BACKUP")" 2>/dev/null || true
          rm -rf "$BACKUP" 2>/dev/null || true
          if ! mv "$APP_PATH" "$BACKUP" 2>/dev/null; then
            log "备份失败，中止"
            exit 1
          fi
        fi

        # 3) 装新版本
        mkdir -p "$(dirname "$APP_PATH")" 2>/dev/null || true
        if ! ditto "$NEW_APP" "$APP_PATH"; then
          log "拷贝失败，回滚旧版本"
          [ -d "$BACKUP" ] && mv "$BACKUP" "$APP_PATH" 2>/dev/null || true
          exit 2
        fi

        # 4) ad-hoc 签名未公证：不去掉隔离属性，Gatekeeper 会拦着不让开
        xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
        xattr -dr com.apple.provenance "$APP_PATH" 2>/dev/null || true

        # 5) 重新启动
        #    ditto 会保留源文件的修改时间，替换后 bundle 的 mtime 是「倒流」的
        #    （比旧包还早），LaunchServices 会觉得 bundle 变了但时间是往回的，
        #    于是拒绝/延迟启动（实测 open 没把新版本拉起来）—— 补一个 touch 把时间抹平
        touch "$APP_PATH" 2>/dev/null || true
        sleep 1
        for _ in 1 2 3; do
          if open "$APP_PATH" >>"$LOG" 2>&1; then
            log "已重新启动"
            break
          fi
          log "启动失败，重试"
          sleep 2
        done
        log "更新完成"
        """
    }
}

// MARK: - 路径与错误

enum UpdatePaths {
    static var cacheRoot: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitLab Pipeline Monitor", isDirectory: true)
    }
    static var workDirectory: URL { cacheRoot.appendingPathComponent("update", isDirectory: true) }
    static var helperScript: URL { cacheRoot.appendingPathComponent("install.sh") }
    static var logFile: URL { cacheRoot.appendingPathComponent("update.log") }
    /// 旧版本备份：新版本成功启动后由 App 自己删掉
    static var previousApp: URL { cacheRoot.appendingPathComponent("previous/GitLab Pipeline Monitor.app") }

    static func prepare() {
        try? FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }
}

enum UpdateError: LocalizedError {
    case invalidURL
    case network(String)
    case rateLimited
    case http(Int)
    case checksum
    case noAppInArchive

    var message: String {
        switch self {
        case .invalidURL: return loc("下载地址无效")
        case .network: return loc("无法连接 GitHub（可能被网络或代理挡住）")
        case .rateLimited: return loc("GitHub 接口访问过于频繁，稍后再试")
        case .http(let code): return "HTTP \(code)"
        case .checksum: return loc("下载校验失败，已放弃更新")
        case .noAppInArchive: return loc("安装包里没找到 App，已放弃更新")
        }
    }

    var errorDescription: String? { message }
}
