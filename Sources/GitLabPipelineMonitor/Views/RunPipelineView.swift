import SwiftUI

struct RunPipelineView: View {
    let project: GitLabProject
    let onDismiss: () -> Void

    @EnvironmentObject var state: AppState
    @State private var branches: [Branch] = []
    @State private var selected: String = ""
    @State private var query = ""
    @State private var loading = false
    @State private var error: String?

    private var filtered: [Branch] {
        let needle = query.trimmed.lowercased()
        let list = needle.isEmpty ? branches : branches.filter { $0.name.lowercased().contains(needle) }
        return Array(list.prefix(200))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                IconButton(system: "chevron.left", help: loc("关闭"), action: onDismiss)
                VStack(alignment: .leading, spacing: 1) {
                    Text(loc("运行新流水线")).font(.system(size: 11, weight: .semibold))
                    Text(project.pathWithNamespace).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            VStack(spacing: 8) {
                SearchField(text: $query, placeholder: loc("选择分支或标签"))
                if loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text(loc("加载中…")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.vertical, 12)
                } else if let error {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color(PipelineStatus.blocked.color))
                        Text(error).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                        Spacer()
                    }
                } else if branches.isEmpty {
                    Text(loc("没有可用的分支")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(filtered) { branch in
                                BranchRow(branch: branch, defaultBranch: project.defaultBranch, isSelected: selected == branch.name) {
                                    selected = branch.name
                                } onDoubleClick: {
                                    run()
                                }
                            }
                        }
                    }
                }
            }
            .padding(10)

            Spacer(minLength: 0)

            Divider()
            HStack(spacing: 8) {
                Button(loc("取消")) { onDismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    run()
                } label: {
                    Label(loc("运行"), systemImage: "play.fill").font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty || state.busyAction == "project-\(project.id)-run")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        error = nil
        let result = await state.fetchBranches(projectID: project.id)
        switch result {
        case .success(let list):
            branches = list
            if selected.isEmpty {
                if let fallback = project.defaultBranch, list.contains(where: { $0.name == fallback }) {
                    selected = fallback
                } else {
                    selected = list.first?.name ?? ""
                }
            }
        case .failure(let failure):
            error = (failure as? GitLabError)?.message ?? failure.localizedDescription
        }
        loading = false
    }

    private func run() {
        guard !selected.isEmpty else { return }
        state.runPipeline(project: project, ref: selected)
        onDismiss()
    }
}

private struct BranchRow: View {
    let branch: Branch
    let defaultBranch: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onDoubleClick: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                Text(branch.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                if branch.name == defaultBranch || branch.isDefault == true {
                    Text("默认")
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
                if let date = branch.commit?.createdAt {
                    Text(Fmt.relative(date)).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : (hover ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { hover = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded(onDoubleClick))
    }
}
