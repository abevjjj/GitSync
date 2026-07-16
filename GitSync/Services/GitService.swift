import Foundation
import SwiftGit2
import Clibgit2 // SwiftGit2 依赖的 C 层，stash 相关 API 目前 SwiftGit2 没有包装，直接调 libgit2

enum GitServiceError: LocalizedError {
    case invalidURL
    case cloneFailed(String)
    case openFailed(String)
    case fetchFailed(String)
    case stashFailed(String)
    case stashPopConflict(String)
    case commitFailed(String)
    case pushFailed(String)
    case notARepo

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "仓库地址无效"
        case .cloneFailed(let m): return "克隆失败：\(m)"
        case .openFailed(let m): return "打开本地仓库失败：\(m)"
        case .fetchFailed(let m): return "拉取失败：\(m)"
        case .stashFailed(let m): return "暂存本地修改失败：\(m)"
        case .stashPopConflict(let m): return "恢复本地修改时发生冲突，需要手动处理：\(m)"
        case .commitFailed(let m): return "提交失败：\(m)"
        case .pushFailed(let m): return "推送失败：\(m)"
        case .notARepo: return "目标文件夹里没有找到 git 仓库"
        }
    }
}

/// download / upload 操作的结果描述，用来在 UI 上给用户一句人话反馈
struct SyncOutcome {
    var message: String
    var hadLocalChangesPreserved: Bool = false
    var stashPopHadConflict: Bool = false
}

final class GitService {

    // MARK: - 凭证

    private func credentials(token: String) -> Credentials {
        // GitHub PAT：HTTPS 场景下用户名随意填（GitHub 不校验），密码用 token
        .plaintext(username: "x-access-token", password: token)
    }

    // MARK: - 一次性 clone（首次配置时调用）

    func clone(remoteURL: URL, to localFolder: URL, branch: String, token: String) throws {
        let creds = credentials(token: token)
        do {
            _ = try Repository.clone(
                from: remoteURL,
                at: localFolder,
                localClone: false,
                bare: false,
                credentials: creds,
                checkoutStrategy: .Safe,
                checkoutProgress: nil
            ).get()
        } catch {
            throw GitServiceError.cloneFailed("\(error)")
        }
    }

    /// 判断目标文件夹是否已经是一个 git 仓库（用于区分"首次 clone"还是"已有仓库直接用"）
    func isExistingRepo(at localFolder: URL) -> Bool {
        let gitDir = localFolder.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // MARK: - 下载（保留本地未提交修改）：stash -> fetch+merge/reset -> pop

    /// 一键"下载"：
    /// 1. 如果本地有未提交修改，先 git stash
    /// 2. fetch 远程 + 把当前分支快进到远程最新（fast-forward）
    /// 3. 如果第 1 步 stash 过，尝试 stash pop
    ///    - 成功：修改被保留在工作区
    ///    - 冲突：不自动处理，把 stash 保留在 stash 列表里，抛错让用户自己去处理（用 git 客户端或后续版本加冲突 UI）
    func download(localFolder: URL, branch: String, token: String) throws -> SyncOutcome {
        var repoPtr: OpaquePointer?
        let openStatus = git_repository_open(&repoPtr, localFolder.path)
        guard openStatus == 0, let repo = repoPtr else {
            throw GitServiceError.openFailed("git_repository_open 返回 \(openStatus)")
        }
        defer { git_repository_free(repo) }

        let hadLocalChanges = repositoryIsDirty(repo)
        var stashed = false

        if hadLocalChanges {
            try stashSave(repo, message: "gitsync-autostash")
            stashed = true
        }

        // fetch + fast-forward 当前分支
        do {
            try fetchAndFastForward(repoPath: localFolder, branch: branch, token: token)
        } catch {
            // fetch 失败的话，如果之前 stash 过，先弹回去，别把用户的修改丢在 stash 里
            if stashed {
                _ = try? stashPop(repo)
            }
            throw error
        }

        if stashed {
            do {
                try stashPop(repo)
            } catch let e as GitServiceError {
                // pop 冲突：stash 保留在列表里（不 drop），提示用户手动处理
                if case .stashPopConflict = e {
                    return SyncOutcome(
                        message: "已拉取远程最新内容，但恢复本地修改时出现冲突，改动仍保存在 git stash 里，需要手动解决（stash 未丢失）。",
                        hadLocalChangesPreserved: true,
                        stashPopHadConflict: true
                    )
                }
                throw e
            }
        }

        return SyncOutcome(
            message: hadLocalChanges ? "已同步远程最新内容，本地未提交修改已保留。" : "已同步远程最新内容。",
            hadLocalChangesPreserved: hadLocalChanges,
            stashPopHadConflict: false
        )
    }

    // MARK: - 上传：add -A + commit + push

    func upload(localFolder: URL, branch: String, token: String, commitMessage: String? = nil) throws -> SyncOutcome {
        guard let repo = try? Repository.at(localFolder).get() else {
            throw GitServiceError.notARepo
        }

        let dirty = try isDirtyViaSwiftGit2(repo)
        if !dirty {
            return SyncOutcome(message: "没有需要提交的改动。")
        }

        // add -A
        do {
            try addAll(localFolder: localFolder)
        } catch {
            throw GitServiceError.commitFailed("\(error)")
        }

        // commit
        let message = commitMessage ?? "GitSync auto commit \(ISO8601DateFormatter().string(from: Date()))"
        do {
            try commitAll(localFolder: localFolder, message: message)
        } catch {
            throw GitServiceError.commitFailed("\(error)")
        }

        // push
        let creds = credentials(token: token)
        do {
            let remote = try repo.remote(named: "origin").get()
            let pushResult = repo.push(remote, credentials: creds, branch: branch)
            if case .failure(let e) = pushResult {
                throw GitServiceError.pushFailed("\(e)。远程可能有新提交，建议先执行「下载」再重试。")
            }
        } catch let e as GitServiceError {
            throw e
        } catch {
            throw GitServiceError.pushFailed("\(error)")
        }

        return SyncOutcome(message: "已提交并推送到远程。")
    }

    // MARK: - libgit2 底层辅助（stash / dirty 检测走 C API，因为 SwiftGit2 未包装 stash）

    private func repositoryIsDirty(_ repo: OpaquePointer) -> Bool {
        var dirty = false
        var opts = git_status_options()
        git_status_init_options(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

        git_status_foreach_ext(repo, &opts, { _, _, _ in
            // 只要回调被触发一次，就说明有变更
            return 0
        }, nil)

        // git_status_foreach_ext 本身不方便直接拿"是否有变更"的布尔值，
        // 用 git_status_list 更直接：
        var list: OpaquePointer?
        if git_status_list_new(&list, repo, &opts) == 0, let list = list {
            let count = git_status_list_entrycount(list)
            dirty = count > 0
            git_status_list_free(list)
        }
        return dirty
    }

    private func isDirtyViaSwiftGit2(_ repo: Repository) throws -> Bool {
        // 通过底层指针复用同一套检测逻辑
        // 注意：如果 SwiftGit2 的 Repository.pointer 不是 public，
        // 这里需要改成重新 git_repository_open(repo.directoryURL.path) 一份
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, repo.directoryURL.path) == 0, let ptr = repoPtr else {
            throw GitServiceError.openFailed("无法重新打开仓库用于状态检测")
        }
        defer { git_repository_free(ptr) }
        return repositoryIsDirty(ptr)
    }

    private func stashSave(_ repo: OpaquePointer, message: String) throws {
        var sig: OpaquePointer?
        _ = git_signature_default(&sig, repo) // 用不到就走 default，失败的话下面 fallback
        if sig == nil {
            git_signature_now(&sig, "GitSync", "gitsync@local")
        }
        defer { if let s = sig { git_signature_free(s) } }

        var oid = git_oid()
        let flags = GIT_STASH_INCLUDE_UNTRACKED.rawValue
        let status = git_stash_save(&oid, repo, sig, message, flags)
        guard status == 0 else {
            throw GitServiceError.stashFailed("git_stash_save 返回 \(status)")
        }
    }

    private func stashPop(_ repo: OpaquePointer) throws {
        var opts = git_stash_apply_options()
        git_stash_apply_options_init(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        opts.flags = GIT_STASH_APPLY_DEFAULT.rawValue

        let status = git_stash_pop(repo, 0, &opts)
        if status == Int32(GIT_ECONFLICT.rawValue) || status < 0 {
            throw GitServiceError.stashPopConflict("git_stash_pop 返回 \(status)")
        }
    }

    private func fetchAndFastForward(repoPath: URL, branch: String, token: String) throws {
        guard let repo = try? Repository.at(repoPath).get() else {
            throw GitServiceError.notARepo
        }
        let creds = credentials(token: token)
        let remote = try repo.remote(named: "origin").get()

        let fetchResult = repo.fetch(remote, credentials: creds)
        if case .failure(let e) = fetchResult {
            throw GitServiceError.fetchFailed("\(e)")
        }

        // 快进当前分支到 origin/<branch>
        do {
            let remoteBranchRef = "refs/remotes/origin/\(branch)"
            guard let remoteOid = try? repo.reference(named: remoteBranchRef).get().oid else {
                throw GitServiceError.fetchFailed("找不到远程分支 \(remoteBranchRef)")
            }
            let localRefName = "refs/heads/\(branch)"
            let checkoutResult = repo.checkout(
                remoteOid,
                strategy: [.Force, .RecreateMissing],
                progress: nil
            )
            if case .failure(let e) = checkoutResult {
                throw GitServiceError.fetchFailed("checkout 失败：\(e)")
            }
            // 移动分支引用指向最新 commit（实现 fast-forward）
            _ = try? repo.reference(named: localRefName).get()
                .set(oid: remoteOid)
        }
    }

    private func addAll(localFolder: URL) throws {
        guard let repo = try? Repository.at(localFolder).get() else {
            throw GitServiceError.notARepo
        }
        var index: OpaquePointer?
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, localFolder.path) == 0, let rp = repoPtr else {
            throw GitServiceError.notARepo
        }
        defer { git_repository_free(rp) }
        guard git_repository_index(&index, rp) == 0, let idx = index else {
            throw GitServiceError.commitFailed("无法打开 index")
        }
        defer { git_index_free(idx) }

        var pathspec = git_strarray(strings: nil, count: 0)
        let status = git_index_add_all(idx, &pathspec, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil)
        guard status == 0 else {
            throw GitServiceError.commitFailed("git_index_add_all 返回 \(status)")
        }
        _ = git_index_write(idx)
        _ = repo // 保持引用避免提前释放
    }

    private func commitAll(localFolder: URL, message: String) throws {
        guard let repo = try? Repository.at(localFolder).get() else {
            throw GitServiceError.notARepo
        }
        let sig = Signature(name: "GitSync", email: "gitsync@local", time: Date(), timeZone: TimeZone.current)
        let head = try? repo.HEAD().get()
        let parentCommit: Commit? = {
            guard let h = head, let oid = h.oid as OID? else { return nil }
            return try? repo.commit(oid).get()
        }()
        let tree = try repo.commit(
            tree: nil, // nil 表示使用当前 index 内容生成 tree（视 SwiftGit2 版本可能需要显式写 index -> tree）
            message: message,
            signature: sig,
            parents: parentCommit.map { [$0] } ?? []
        ).get()
        _ = tree
    }
}
