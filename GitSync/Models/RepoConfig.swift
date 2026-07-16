import Foundation

/// 一个"仓库配置" = 一次性设置好之后长期复用的同步单元
struct RepoConfig: Codable, Identifiable {
    var id: UUID = UUID()
    /// GitHub 仓库地址，例如 https://github.com/user/repo.git
    var remoteURLString: String
    /// 默认分支，例如 main
    var branch: String
    /// 本地目标文件夹的 security-scoped bookmark（Base64 存储）
    var bookmarkData: Data
    /// 展示用的名字（默认取仓库名）
    var displayName: String

    var remoteURL: URL? { URL(string: remoteURLString) }
}

/// 所有仓库配置的存取（列表存 UserDefaults，PAT 单独存 Keychain）
enum RepoConfigStore {
    private static let key = "com.shai.gitsync.repoConfigs"

    static func loadAll() -> [RepoConfig] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RepoConfig].self, from: data) else {
            return []
        }
        return list
    }

    static func saveAll(_ configs: [RepoConfig]) {
        guard let data = try? JSONEncoder().encode(configs) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func add(_ config: RepoConfig) {
        var all = loadAll()
        all.append(config)
        saveAll(all)
    }

    static func update(_ config: RepoConfig) {
        var all = loadAll()
        if let idx = all.firstIndex(where: { $0.id == config.id }) {
            all[idx] = config
            saveAll(all)
        }
    }

    static func remove(_ config: RepoConfig) {
        var all = loadAll()
        all.removeAll { $0.id == config.id }
        saveAll(all)
        KeychainHelper.deleteToken(forConfigId: config.id)
    }
}
