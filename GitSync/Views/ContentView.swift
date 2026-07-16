import SwiftUI

struct ContentView: View {
    @State private var configs: [RepoConfig] = RepoConfigStore.loadAll()
    @State private var showingConfig = false
    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var resultMessage: String?

    private let gitService = GitService()

    var body: some View {
        NavigationStack {
            List {
                ForEach(configs) { config in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(config.displayName).font(.headline)
                        Text(config.remoteURLString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        HStack {
                            Button {
                                run(.download, config: config)
                            } label: {
                                Label("下载", systemImage: "arrow.down.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                run(.upload, config: config)
                            } label: {
                                Label("上传", systemImage: "arrow.up.circle.fill")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { indexSet in
                    for i in indexSet { RepoConfigStore.remove(configs[i]) }
                    configs = RepoConfigStore.loadAll()
                }
            }
            .navigationTitle("GitSync")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingConfig = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingConfig) {
                ConfigView { newConfig in
                    configs = RepoConfigStore.loadAll()
                }
            }
            .overlay {
                if let busyMessage {
                    ProgressView(busyMessage)
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("出错了", isPresented: .constant(errorMessage != nil), actions: {
                Button("好") { errorMessage = nil }
            }, message: {
                Text(errorMessage ?? "")
            })
            .alert("完成", isPresented: .constant(resultMessage != nil), actions: {
                Button("好") { resultMessage = nil }
            }, message: {
                Text(resultMessage ?? "")
            })
        }
    }

    private enum Action { case download, upload }

    private func run(_ action: Action, config: RepoConfig) {
        guard let token = KeychainHelper.loadToken(forConfigId: config.id) else {
            errorMessage = "没有找到该仓库的访问令牌，请重新配置。"
            return
        }

        busyMessage = action == .download ? "正在下载最新内容…" : "正在提交并推送…"

        DispatchQueue.global(qos: .userInitiated).async {
            defer { DispatchQueue.main.async { busyMessage = nil } }
            do {
                let folder = try BookmarkStore.resolve(config.bookmarkData)
                defer { folder.stopAccessingSecurityScopedResource() }

                let outcome: SyncOutcome
                switch action {
                case .download:
                    outcome = try gitService.download(localFolder: folder, branch: config.branch, token: token)
                case .upload:
                    outcome = try gitService.upload(localFolder: folder, branch: config.branch, token: token)
                }

                DispatchQueue.main.async {
                    resultMessage = outcome.message
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
