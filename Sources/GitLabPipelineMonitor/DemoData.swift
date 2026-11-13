import Foundation

/// 演示数据：--demo 启动时填充，用于在没有令牌的情况下预览界面。
@MainActor
enum DemoData {
    static func apply(to state: AppState) {
        let now = Date()

        state.demoHost = "gitlab.example.com"
        state.user = GitLabUser(id: 1, username: "demo.user", name: "Demo User", avatarURL: nil, webURL: nil)
        state.gitlabVersion = "17.5.1-ee"
        state.fatalErrorMessage = nil

        func project(_ id: Int, _ path: String, _ branch: String, _ minutes: Int, starred: Bool = true) -> GitLabProject {
            GitLabProject(id: id, name: path.components(separatedBy: "/").last ?? path,
                          pathWithNamespace: path,
                          webURL: "https://gitlab.example.com/" + path,
                          defaultBranch: branch,
                          lastActivityAt: now.addingTimeInterval(-Double(minutes * 60)),
                          starCount: 3, archived: false, starred: starred)
        }

        func pipeline(_ id: Int, projectID: Int, iid: Int, ref: String, sha: String,
                      status: PipelineStatus, minutesAgo: Int, duration: Double?, user: String) -> Pipeline {
            var item = Pipeline(id: id, iid: iid, projectID: projectID, name: nil, sha: sha, ref: ref,
                                status: status, source: "push", createdAt: now.addingTimeInterval(-Double(minutesAgo * 60)),
                                startedAt: now.addingTimeInterval(-Double(minutesAgo * 60)), finishedAt: nil,
                                updatedAt: now.addingTimeInterval(-Double(minutesAgo * 60)), duration: duration,
                                covered: nil, user: GitLabUser(id: 2, username: user, name: user, avatarURL: nil, webURL: nil))
            if status == .success { item.covered = "87.2" }
            return item
        }

        let projects = [
            project(101, "cross-components/example-survey", "main", 4),
            project(102, "bss/web-console", "develop", 12),
            project(103, "bss/feedback-portal", "main", 31),
            project(104, "infra/deploy-tools", "staging", 88),
            project(105, "design/ui-archive", "main", 260, starred: true)
        ]
        state.starredProjects = projects
        state.memberProjects = projects + [project(106, "bss/example-gateway", "main", 420, starred: false)]

        state.pipelines = [
            101: [
                pipeline(9001, projectID: 101, iid: 482, ref: "main", sha: "a1b2c3d4e5f6", status: .running, minutesAgo: 4, duration: nil, user: "demo.user"),
                pipeline(9002, projectID: 101, iid: 481, ref: "main", sha: "9f8e7d6c", status: .success, minutesAgo: 55, duration: 412, user: "ci-bot"),
                pipeline(9003, projectID: 101, iid: 480, ref: "feature/kyc-form", sha: "1a2b3c4d", status: .failed, minutesAgo: 130, duration: 208, user: "demo.dev")
            ],
            102: [
                pipeline(9011, projectID: 102, iid: 1291, ref: "develop", sha: "55aa66bb77cc", status: .failed, minutesAgo: 12, duration: 96, user: "demo.user"),
                pipeline(9012, projectID: 102, iid: 1290, ref: "feature/module-designer", sha: "deedbeef", status: .success, minutesAgo: 70, duration: 505, user: "demo.dev"),
                pipeline(9013, projectID: 102, iid: 1289, ref: "develop", sha: "00112233", status: .success, minutesAgo: 190, duration: 480, user: "ci-bot")
            ],
            103: [
                pipeline(9021, projectID: 103, iid: 77, ref: "main", sha: "cafe1234", status: .success, minutesAgo: 31, duration: 233, user: "demo.user"),
                pipeline(9022, projectID: 103, iid: 76, ref: "main", sha: "badd1ca7", status: .canceled, minutesAgo: 210, duration: 41, user: "demo.tester")
            ],
            104: [
                pipeline(9031, projectID: 104, iid: 315, ref: "staging", sha: "feedface", status: .pending, minutesAgo: 1, duration: nil, user: "ci-bot"),
                pipeline(9032, projectID: 104, iid: 314, ref: "staging", sha: "beefc0de", status: .success, minutesAgo: 95, duration: 1204, user: "ci-bot")
            ],
            105: [
                pipeline(9041, projectID: 105, iid: 8, ref: "main", sha: "12345678", status: .manual, minutesAgo: 260, duration: 12, user: "design.bot")
            ]
        ]
        state.projectErrors = [:]
        state.lastUpdated = now
    }

    // MARK: 演示作业 / 提交

    static func jobs(for pipeline: Pipeline, project: GitLabProject) -> [Job] {
        let base = Date()

        func job(_ id: Int, _ stage: String, _ name: String, _ status: PipelineStatus,
                 minutes: Int, duration: Double?, reason: String? = nil, allow: Bool? = nil) -> Job {
            Job(
                id: id, name: name, stage: stage, status: status, ref: pipeline.ref, duration: duration,
                startedAt: base.addingTimeInterval(-Double(minutes * 60)),
                finishedAt: status.isActive ? nil : base.addingTimeInterval(-Double(max(minutes - 1, 0) * 60)),
                webURL: project.webURL + "/-/jobs/" + String(id),
                failureReason: reason,
                allowFailure: allow
            )
        }

        switch pipeline.status {
        case .running:
            return [
                job(1, "install", "dependencies", .success, minutes: 12, duration: 96),
                job(2, "build", "compile", .success, minutes: 9, duration: 214),
                job(3, "test", "unit", .running, minutes: 3, duration: nil),
                job(4, "test", "e2e", .created, minutes: 3, duration: nil),
                job(5, "deploy", "staging", .created, minutes: 3, duration: nil)
            ]
        case .failed:
            return [
                job(6, "install", "dependencies", .success, minutes: 20, duration: 88),
                job(7, "build", "compile", .success, minutes: 16, duration: 205),
                job(8, "test", "unit", .failed, minutes: 12, duration: 173, reason: "执行脚本失败 exit code 1，2 个用例未通过"),
                job(9, "test", "lint", .success, minutes: 12, duration: 41),
                job(10, "deploy", "staging", .canceled, minutes: 11, duration: nil, allow: true)
            ]
        case .success:
            return [
                job(11, "install", "dependencies", .success, minutes: 60, duration: 90),
                job(12, "build", "compile", .success, minutes: 56, duration: 198),
                job(13, "test", "unit", .success, minutes: 50, duration: 320),
                job(14, "deploy", "staging", .success, minutes: 44, duration: 122)
            ]
        case .canceled:
            return [
                job(15, "install", "dependencies", .success, minutes: 200, duration: 84),
                job(16, "build", "compile", .canceled, minutes: 196, duration: 61)
            ]
        case .pending, .scheduled, .created, .waitingForResource, .preparation:
            return [
                job(17, "install", "dependencies", .pending, minutes: 1, duration: nil),
                job(18, "build", "compile", .created, minutes: 1, duration: nil)
            ]
        default:
            return [job(19, "test", "unit", pipeline.status, minutes: 30, duration: 60)]
        }
    }

    static func commit(for pipeline: Pipeline) -> Commit {
        Commit(
            id: pipeline.sha,
            shortID: pipeline.shortSHA,
            title: "feat: 问卷式 KYC 模块支持字段语义标签与档案同步",
            message: "feat: 问卷式 KYC 模块支持字段语义标签与档案同步",
            authorName: pipeline.user?.name ?? "Demo User",
            createdAt: pipeline.createdAt,
            webURL: nil
        )
    }
}
