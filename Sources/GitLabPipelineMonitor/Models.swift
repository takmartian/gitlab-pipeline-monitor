import Foundation
import AppKit

// MARK: - 解码辅助

enum GitLabDate {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return fractional.date(from: raw) ?? plain.date(from: raw)
    }
}

/// 宽松取值：字段缺失或类型不符时返回 nil，而不是让整次解码失败。
/// 自建 GitLab 的版本差异很大，宁可少一个字段也不要整页打不开。
extension KeyedDecodingContainer {
    func opt<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    func str(_ key: Key) -> String? { opt(String.self, key) }
    func int(_ key: Key) -> Int? { opt(Int.self, key) }
    func dbl(_ key: Key) -> Double? { opt(Double.self, key) }
    func flag(_ key: Key) -> Bool? { opt(Bool.self, key) }

    func date(_ key: Key) -> Date? {
        if let value = str(key) { return GitLabDate.parse(value) }
        if let value = dbl(key) { return Date(timeIntervalSince1970: value) }
        return nil
    }
}

// MARK: - 状态

enum PipelineStatus: String, Codable, CaseIterable, Hashable {
    case created
    case waitingForResource = "waiting_for_resource"
    case preparation
    case pending
    case running
    case success
    case failed
    case canceled
    case skipped
    case manual
    case scheduled
    case blocked
    case notStarted = "not_started"
    case unknown

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = (try? c.decode(String.self)) ?? ""
        self = PipelineStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .created: return loc("已创建")
        case .waitingForResource: return loc("等待资源")
        case .preparation: return loc("准备中")
        case .pending: return loc("排队中")
        case .running: return loc("运行中")
        case .success: return loc("已通过")
        case .failed: return loc("已失败")
        case .canceled: return loc("已取消")
        case .skipped: return loc("已跳过")
        case .manual: return loc("手动")
        case .scheduled: return loc("已计划")
        case .blocked: return loc("已阻塞")
        case .notStarted: return loc("未开始")
        case .unknown: return loc("未知")
        }
    }

    var color: NSColor {
        switch self {
        case .success: return NSColor(srgbRed: 0.20, green: 0.72, blue: 0.36, alpha: 1)
        case .failed: return NSColor(srgbRed: 0.94, green: 0.27, blue: 0.27, alpha: 1)
        case .running: return NSColor(srgbRed: 0.22, green: 0.55, blue: 0.98, alpha: 1)
        case .pending, .scheduled, .waitingForResource, .preparation:
            return NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1)
        case .canceled: return NSColor(srgbRed: 0.55, green: 0.58, blue: 0.62, alpha: 1)
        case .manual: return NSColor(srgbRed: 0.62, green: 0.45, blue: 0.90, alpha: 1)
        case .blocked: return NSColor(srgbRed: 0.85, green: 0.45, blue: 0.20, alpha: 1)
        case .skipped, .notStarted, .created, .unknown: return NSColor.secondaryLabelColor
        }
    }

    var symbol: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .failed: return "x.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .pending, .scheduled: return "clock.circle"
        case .waitingForResource, .preparation: return "hourglass.circle.fill"
        case .canceled: return "minus.circle.fill"
        case .manual: return "hand.raised.circle.fill"
        case .blocked: return "lock.circle.fill"
        case .skipped: return "forward.circle.fill"
        case .notStarted, .created, .unknown: return "circle.dashed"
        }
    }

    /// GitLab 只对 failed / canceled / success 提供 retry，运行中也允许（会重跑未完成作业）
    var canRetry: Bool { self == .failed || self == .canceled || self == .success || self == .running }
    var canCancel: Bool { isActive }
    var isActive: Bool {
        self == .running || self == .pending || self == .scheduled || self == .created
            || self == .waitingForResource || self == .preparation
    }
}

// MARK: - 用户

struct GitLabUser: Codable, Identifiable, Hashable {
    let id: Int
    var username: String
    var name: String
    var avatarURL: String?
    var webURL: String?

    enum CodingKeys: String, CodingKey {
        case id, username, name
        case avatarURL = "avatar_url"
        case webURL = "web_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        username = c.str(.username) ?? "?"
        name = c.str(.name) ?? username
        avatarURL = c.str(.avatarURL)
        webURL = c.str(.webURL)
    }

    init(id: Int, username: String, name: String, avatarURL: String?, webURL: String?) {
        self.id = id
        self.username = username
        self.name = name
        self.avatarURL = avatarURL
        self.webURL = webURL
    }
}

// MARK: - 项目

struct GitLabProject: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    var pathWithNamespace: String
    var webURL: String
    var defaultBranch: String?
    var lastActivityAt: Date?
    var starCount: Int
    var archived: Bool
    /// 是否已打星：由拉取来源标记，不参与解码
    var starred: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, archived
        case pathWithNamespace = "path_with_namespace"
        case webURL = "web_url"
        case defaultBranch = "default_branch"
        case lastActivityAt = "last_activity_at"
        case starCount = "star_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        name = c.str(.name) ?? "project"
        pathWithNamespace = c.str(.pathWithNamespace) ?? name
        webURL = c.str(.webURL) ?? ""
        defaultBranch = c.str(.defaultBranch)
        lastActivityAt = c.date(.lastActivityAt)
        starCount = c.int(.starCount) ?? 0
        archived = c.flag(.archived) ?? false
        starred = false
    }

    init(id: Int, name: String, pathWithNamespace: String, webURL: String, defaultBranch: String?,
         lastActivityAt: Date?, starCount: Int, archived: Bool, starred: Bool) {
        self.id = id
        self.name = name
        self.pathWithNamespace = pathWithNamespace
        self.webURL = webURL
        self.defaultBranch = defaultBranch
        self.lastActivityAt = lastActivityAt
        self.starCount = starCount
        self.archived = archived
        self.starred = starred
    }

    var namespace: String {
        pathWithNamespace.components(separatedBy: "/").dropLast().joined(separator: "/")
    }

    var shortPath: String {
        pathWithNamespace.components(separatedBy: "/").last ?? pathWithNamespace
    }

    /// 项目主页。web_url 万一没取到（字段缺失或版本差异），用服务器地址 + 路径自己拼一个，
    /// 免得「在项目页打开」点开一个空字符串
    func resolvedWebURL(base: URL?) -> String {
        let value = webURL.trimmed
        if !value.isEmpty { return value }
        if let base { return base.absoluteString + "/" + pathWithNamespace }
        return ""
    }

    /// 流水线列表页。GitLab 13 起内部页面挂在 /-/ 命名空间下，
    /// 用 /group/project/pipelines 这种旧路径要靠服务端重定向，这里直接给准确的
    func pipelinesURL(base: URL?) -> String { resolvedWebURL(base: base) + "/-/pipelines" }

    /// 某条流水线的详情页
    func pipelineURL(_ pipeline: Pipeline, base: URL?) -> String { pipelinesURL(base: base) + "/\(pipeline.id)" }
}

// MARK: - 流水线

struct Pipeline: Codable, Identifiable, Hashable {
    let id: Int
    var iid: Int
    var projectID: Int?
    var name: String?
    var sha: String
    var ref: String
    var status: PipelineStatus
    var source: String?
    var createdAt: Date?
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date?
    var duration: Double?
    var covered: String?
    var user: GitLabUser?

    enum CodingKeys: String, CodingKey {
        case id, iid, name, sha, ref, status, source, duration, user
        // GitLab 的字段名是 coverage，不叫 covered
        case covered = "coverage"
        case projectID = "project_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        iid = c.int(.iid) ?? 0
        projectID = c.int(.projectID)
        name = c.str(.name)
        sha = c.str(.sha) ?? ""
        ref = c.str(.ref) ?? ""
        status = c.opt(PipelineStatus.self, .status) ?? .unknown
        source = c.str(.source)
        createdAt = c.date(.createdAt)
        startedAt = c.date(.startedAt)
        finishedAt = c.date(.finishedAt)
        updatedAt = c.date(.updatedAt)
        duration = c.dbl(.duration)
        covered = c.str(.covered)
        user = c.opt(GitLabUser.self, .user)
    }

    init(id: Int, iid: Int, projectID: Int?, name: String?, sha: String, ref: String, status: PipelineStatus,
         source: String?, createdAt: Date?, startedAt: Date?, finishedAt: Date?, updatedAt: Date?,
         duration: Double?, covered: String?, user: GitLabUser?) {
        self.id = id
        self.iid = iid
        self.projectID = projectID
        self.name = name
        self.sha = sha
        self.ref = ref
        self.status = status
        self.source = source
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.covered = covered
        self.user = user
    }

    var shortSHA: String { String(sha.prefix(8)) }
    /// 列表接口不返回 project_id，归属关系在加载时补齐
    var sortDate: Date { updatedAt ?? createdAt ?? startedAt ?? finishedAt ?? .distantPast }
}

// MARK: - 作业

struct Job: Codable, Identifiable, Hashable {
    let id: Int
    var name: String
    var stage: String
    var status: PipelineStatus
    var ref: String?
    var duration: Double?
    var startedAt: Date?
    var finishedAt: Date?
    var webURL: String?
    var failureReason: String?
    var allowFailure: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, stage, status, ref, duration
        case webURL = "web_url"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case failureReason = "failure_reason"
        case allowFailure = "allow_failure"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.int(.id) ?? 0
        name = c.str(.name) ?? "job"
        stage = c.str(.stage) ?? "default"
        status = c.opt(PipelineStatus.self, .status) ?? .unknown
        ref = c.str(.ref)
        duration = c.dbl(.duration)
        startedAt = c.date(.startedAt)
        finishedAt = c.date(.finishedAt)
        webURL = c.str(.webURL)
        failureReason = c.str(.failureReason)
        allowFailure = c.flag(.allowFailure)
    }

    init(id: Int, name: String, stage: String, status: PipelineStatus, ref: String?, duration: Double?,
         startedAt: Date?, finishedAt: Date?, webURL: String?, failureReason: String?, allowFailure: Bool?) {
        self.id = id
        self.name = name
        self.stage = stage
        self.status = status
        self.ref = ref
        self.duration = duration
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.webURL = webURL
        self.failureReason = failureReason
        self.allowFailure = allowFailure
    }

    /// 作业日志页；接口没给 web_url 时用项目地址自己拼
    func resolvedWebURL(base: URL?, project: GitLabProject?) -> String {
        let value = webURL?.trimmed ?? ""
        if !value.isEmpty { return value }
        guard let project else { return "" }
        return project.resolvedWebURL(base: base) + "/-/jobs/\(id)"
    }
}

// MARK: - 提交 / 分支 / 版本

struct Commit: Codable, Identifiable, Hashable {
    let id: String
    var shortID: String?
    var title: String?
    var message: String?
    var authorName: String?
    var createdAt: Date?
    var webURL: String?

    enum CodingKeys: String, CodingKey {
        case id, title, message
        case shortID = "short_id"
        case authorName = "author_name"
        case createdAt = "created_at"
        case webURL = "web_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.str(.id) ?? ""
        shortID = c.str(.shortID)
        title = c.str(.title)
        message = c.str(.message)
        authorName = c.str(.authorName)
        createdAt = c.date(.createdAt)
        webURL = c.str(.webURL)
    }

    init(id: String, shortID: String?, title: String?, message: String?, authorName: String?,
         createdAt: Date?, webURL: String?) {
        self.id = id
        self.shortID = shortID
        self.title = title
        self.message = message
        self.authorName = authorName
        self.createdAt = createdAt
        self.webURL = webURL
    }
}

struct Branch: Codable, Identifiable, Hashable {
    var name: String
    var merged: Bool?
    var isDefault: Bool?
    var commit: Commit?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, merged, commit
        case isDefault = "default"
    }
}

struct GitLabVersion: Codable {
    var version: String?
    var revision: String?
}
