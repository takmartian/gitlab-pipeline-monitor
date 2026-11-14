import Foundation

enum GitLabAuthMode: String, CaseIterable, Identifiable {
    case pat
    case oauth
    var id: String { rawValue }
    var label: String { self == .pat ? "个人访问令牌 (PRIVATE-TOKEN)" : "OAuth 令牌 (Bearer)" }
}

struct GitLabError: LocalizedError, Hashable {
    enum Kind: Hashable {
        case notConfigured, invalidURL, html, network, unauthorized, forbidden
        case notFound, rateLimited, server, decoding, canceled, http(Int)
    }

    let kind: Kind
    /// 服务器返回的原始信息，用于在设置页排查问题
    var detail: String?

    init(_ kind: Kind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }

    var message: String {
        let base: String
        switch kind {
        case .notConfigured: base = loc("未配置服务器地址或令牌")
        case .invalidURL: base = loc("服务器地址无效，请填写形如 https://gitlab.example.com 的地址")
        case .html: base = loc("服务器返回的是网页而不是 API，请检查地址是否指向 GitLab 根地址")
        case .network: base = loc("无法连接服务器，请检查地址、网络或 VPN")
        case .unauthorized: base = loc("令牌无效或已过期（401）")
        case .forbidden: base = loc("没有权限（403）")
        case .notFound: base = loc("项目不存在或已被删除（404）")
        case .rateLimited: base = loc("请求过于频繁（429），请加大刷新间隔")
        case .server: base = loc("服务器错误")
        case .decoding: base = loc("数据解析失败，可能不是 GitLab 服务器")
        case .canceled: base = loc("请求已取消")
        case .http(let code): base = "HTTP \(code)"
        }
        if let detail, !detail.isEmpty { return "\(base)：\(detail)" }
        return base
    }

    var errorDescription: String? { message }
}

/// GitLab REST API v4 的薄封装。
/// 只做这个工具需要的几件事：读用户、读项目、读流水线/作业、重试/取消/新建流水线。
struct GitLabClient {
    let baseURL: URL
    let token: String
    let authMode: GitLabAuthMode
    private let session: URLSession

    /// 这里**不能**设 keyDecodingStrategy = .convertFromSnakeCase：
    /// 所有模型都自定义了 CodingKeys，按 JSON 原样 key 取值（case webURL = "web_url"），
    /// 而该策略会先把 web_url 改写成 webUrl，于是这些字段全部静默取不到 ——
    /// web_url 空 → 「在项目页打开」拼出 "/pipelines" → LaunchServices 当文件打开报 -50；
    /// updated_at / last_activity_at 空 → 时间一律显示「2,025 年前」；
    /// job 的 web_url 空 → 「查看作业日志」按钮永远不出现。
    private static let decoder: JSONDecoder = JSONDecoder()

    init(baseURL: URL, token: String, authMode: GitLabAuthMode) {
        self.baseURL = baseURL
        self.token = token
        self.authMode = authMode

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 45
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "User-Agent": "GitLabPipelineMonitor/\(AppInfo.version)",
            "Accept": "application/json"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - 请求

    private struct Raw {
        let data: Data
        let status: Int
        let nextPages: [String]
        let contentType: String
    }

    private func makeURL(_ path: String, query: [URLQueryItem]) -> URL? {
        guard var comps = URLComponents(string: baseURL.absoluteString + "/api/v4" + path) else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        return comps.url
    }

    /// 路径片段转义（分支名可能带 / 和中文）
    private func seg(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func perform(_ path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> Raw {
        guard let url = makeURL(path, query: query) else { throw GitLabError(.invalidURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        switch authMode {
        case .pat: request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        case .oauth: request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw GitLabError(.canceled) }
            throw GitLabError(.network, detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw GitLabError(.decoding) }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let next = (http.value(forHTTPHeaderField: "X-Next-Page") ?? "").trimmingCharacters(in: .whitespaces)

        switch http.statusCode {
        case 200..<300:
            if type.contains("text/html") { throw GitLabError(.html) }
            return Raw(data: data, status: http.statusCode, nextPages: next.isEmpty ? [] : [next], contentType: type)
        case 401: throw GitLabError(.unauthorized, detail: Self.serverMessage(data))
        case 403: throw GitLabError(.forbidden, detail: Self.serverMessage(data))
        case 404: throw GitLabError(.notFound, detail: Self.serverMessage(data))
        case 429: throw GitLabError(.rateLimited, detail: Self.serverMessage(data))
        case 500..<600: throw GitLabError(.server, detail: Self.serverMessage(data) ?? "HTTP \(http.statusCode)")
        default: throw GitLabError(.http(http.statusCode), detail: Self.serverMessage(data))
        }
    }

    /// 从 GitLab 的错误响应里尽量捞出人话：message / error / errors / error_description
    private static func serverMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let string = object as? String { return string.nilIfEmpty }
        guard let dict = object as? [String: Any] else { return nil }

        for key in ["message", "error", "error_description"] {
            guard let value = dict[key] else { continue }
            if let string = value as? String, !string.isEmpty { return string }
            if let array = value as? [String], !array.isEmpty { return array.joined(separator: ", ") }
            if let nested = value as? [String: Any], !nested.isEmpty {
                let parts = nested.map { "\($0.key): \($0.value)" }
                return parts.joined(separator: ", ")
            }
        }
        if let errors = dict["errors"] as? [String: Any], !errors.isEmpty {
            return errors.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        }
        return nil
    }

    private func get<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem] = []) async throws -> T {
        let raw = try await perform(path, query: query)
        do {
            return try Self.decoder.decode(type, from: raw.data)
        } catch {
            if raw.contentType.contains("text/html") { throw GitLabError(.html) }
            throw GitLabError(.decoding, detail: String(describing: type))
        }
    }

    private func getList<T: Decodable>(_ type: T.Type, _ path: String, query: [URLQueryItem], maxPages: Int) async throws -> [T] {
        var all: [T] = []
        var page = "1"
        var index = 0
        var effectiveQuery = query
        while index < maxPages {
            index += 1
            if let existing = effectiveQuery.firstIndex(where: { $0.name == "page" }) {
                effectiveQuery[existing].value = page
            } else {
                effectiveQuery.append(URLQueryItem(name: "page", value: page))
            }
            let raw = try await perform(path, query: effectiveQuery)
            let batch: [T]
            do {
                batch = try Self.decoder.decode([T].self, from: raw.data)
            } catch {
                if raw.contentType.contains("text/html") { throw GitLabError(.html) }
                throw GitLabError(.decoding, detail: String(describing: T.self))
            }
            all.append(contentsOf: batch)
            guard let next = raw.nextPages.first, !next.isEmpty, !batch.isEmpty else { break }
            page = next
        }
        return all
    }

    @discardableResult
    private func post(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform(path, query: query, method: "POST").data
    }

    // MARK: - 接口

    func currentUser() async throws -> GitLabUser {
        try await get(GitLabUser.self, "/user")
    }

    func version() async throws -> GitLabVersion {
        try await get(GitLabVersion.self, "/version")
    }

    /// 打星项目
    func starredProjects() async throws -> [GitLabProject] {
        var list = try await getList(GitLabProject.self, "/projects", query: [
            URLQueryItem(name: "starred", value: "true"),
            URLQueryItem(name: "order_by", value: "last_activity_at"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "archived", value: "false")
        ], maxPages: 5)
        for index in list.indices { list[index].starred = true }
        return list
    }

    /// 我参与的项目（用于手动勾选未打星的项目）
    func memberProjects() async throws -> [GitLabProject] {
        try await getList(GitLabProject.self, "/projects", query: [
            URLQueryItem(name: "membership", value: "true"),
            URLQueryItem(name: "order_by", value: "last_activity_at"),
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "archived", value: "false")
        ], maxPages: 5)
    }

    func pipelines(projectID: Int, limit: Int) async throws -> [Pipeline] {
        var list = try await getList(Pipeline.self, "/projects/\(projectID)/pipelines", query: [
            URLQueryItem(name: "per_page", value: String(max(1, min(limit, 40))))
        ], maxPages: 1)
        for index in list.indices { list[index].projectID = projectID }
        return list
    }

    func jobs(projectID: Int, pipelineID: Int) async throws -> [Job] {
        try await getList(Job.self, "/projects/\(projectID)/pipelines/\(pipelineID)/jobs", query: [
            URLQueryItem(name: "per_page", value: "100")
        ], maxPages: 3)
    }

    func commit(projectID: Int, sha: String) async throws -> Commit {
        try await get(Commit.self, "/projects/\(projectID)/repository/commits/\(seg(sha))")
    }

    func branches(projectID: Int) async throws -> [Branch] {
        try await getList(Branch.self, "/projects/\(projectID)/repository/branches", query: [
            URLQueryItem(name: "per_page", value: "100"),
            URLQueryItem(name: "order_by", value: "updated_at")
        ], maxPages: 2)
    }

    /// 打星 / 取消打星
    @discardableResult
    func star(projectID: Int) async throws -> Data {
        try await post("/projects/\(projectID)/star")
    }

    @discardableResult
    func unstar(projectID: Int) async throws -> Data {
        try await perform("/projects/\(projectID)/star", method: "DELETE").data
    }

    @discardableResult
    func retryPipeline(projectID: Int, pipelineID: Int) async throws -> Data {
        try await post("/projects/\(projectID)/pipelines/\(pipelineID)/retry")
    }

    @discardableResult
    func cancelPipeline(projectID: Int, pipelineID: Int) async throws -> Data {
        try await post("/projects/\(projectID)/pipelines/\(pipelineID)/cancel")
    }

    @discardableResult
    func createPipeline(projectID: Int, ref: String) async throws -> Data {
        try await post("/projects/\(projectID)/pipeline", query: [URLQueryItem(name: "ref", value: ref)])
    }

    @discardableResult
    func retryJob(projectID: Int, jobID: Int) async throws -> Data {
        try await post("/projects/\(projectID)/jobs/\(jobID)/retry")
    }

    @discardableResult
    func cancelJob(projectID: Int, jobID: Int) async throws -> Data {
        try await post("/projects/\(projectID)/jobs/\(jobID)/cancel")
    }
}
