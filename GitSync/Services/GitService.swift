import Foundation
import SwiftGit2
import Clibgit2 // SwiftGit2(SwiftGit3 fork)依赖的 C 层；stash 和认证 fetch 目前没有高层封装，直接调用

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

// MARK: - 手写的认证回调（SwiftGit3 内部的 credentials 回调是 internal，外部模块调不到，只能自己实现一份）

/// 简单起见：同一时间只做一个 git 操作，用一个文件私有的静态变量传当前操作用的 PAT。
/// 这是个人工具在"串行执行 git 操作"前提下的实用取舍，不是通用做法。
private enum CurrentAuth {
    static var username: String = "x-access-token"
    static var password: String = ""
}

/// 必须是没有闭包捕获的顶层函数，才能当 C 函数指针传给 libgit2
private func gitSyncCredentialsCallback(
    cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
    url: UnsafePointer<CChar>?,
    usernameFromURL: UnsafePointer<CChar>?,
    allowedTypes: UInt32,
    payload: UnsafeMutableRawPointer?
) -> Int32 {
    let result = git_cred_userpass_plaintext_new(cred, CurrentAuth.username, CurrentAuth.password)
    return result == GIT_OK.rawValue ? 0 : -1
}

final class GitService {

    // MARK: - 一次性 clone（首次配置时调用，用 SwiftGit2 自带的 clone，它内部已经处理好认证）

    func clone(remoteURL: URL, to localFolder: URL, branch: String, token: String) throws {
        let creds = Credentials.plaintext(username: "x-access-token", password: token)
        let result = Repository.clone(
            from: remoteURL,
            to: localFolder,
            localClone: false,
            bare: false,
            credentials: creds,
            checkoutStrategy: .Safe,
            checkoutProgress: nil
        )
        if case .failure(let e) = result {
            throw GitServiceError.cloneFailed("\(e)")
        }
    }

    /// 判断目标文件夹是否已经是一个 git 仓库
    func isExistingRepo(at localFolder: URL) -> Bool {
        let gitDir = localFolder.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitDir.path)
    }

    // MARK: - 下载（保留本地未提交修改）：stash -> fetch+fast-forward -> pop

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

        do {
            try authenticatedFetchAndFastForward(localFolder: localFolder, branch: branch, token: token)
        } catch {
            if stashed {
                _ = try? stashPop(repo)
            }
            throw error
        }

        if stashed {
            do {
                try stashPop(repo)
            } catch let e as GitServiceError {
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
        guard case .success(let repo) = Repository.at(localFolder) else {
            throw GitServiceError.notARepo
        }

        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, localFolder.path) == 0, let checkPtr = repoPtr else {
            throw GitServiceError.notARepo
        }
        let dirty = repositoryIsDirty(checkPtr)
        git_repository_free(checkPtr)

        if !dirty {
            return SyncOutcome(message: "没有需要提交的改动。")
        }

        // add -A（"." 作为 pathspec 匹配所有文件）
        if case .failure(let e) = repo.add(path: ".") {
            throw GitServiceError.commitFailed("\(e)")
        }

        // commit（用 SwiftGit2 自带的高层 API：基于当前 index 内容 + HEAD 作为 parent）
        let message = commitMessage ?? "GitSync auto commit \(ISO8601DateFormatter().string(from: Date()))"
        let signature = Signature(name: "GitSync", email: "gitsync@local")
        if case .failure(let e) = repo.commit(message: message, signature: signature) {
            throw GitServiceError.commitFailed("\(e)")
        }

        // push（SwiftGit2 这份 push 直接接受 username/password，不需要额外包 Credentials）
        CurrentAuth.username = "x-access-token"
        CurrentAuth.password = token
        repo.push(repo, "x-access-token", token, branch)
        // 注意：这个 fork 的 push() 目前没有返回值，无法在这里拿到"是否真的推送成功"的明确结果，
        // 如果远程有冲突，libgit2 层会打印错误但不会抛出 Swift 错误——这是当前实现的已知局限。

        return SyncOutcome(message: "已提交并尝试推送到远程（如果远程有新提交导致冲突，请先执行「下载」）。")
    }

    // MARK: - 底层辅助：脏检测 / stash（走 Clibgit2 C API，因为 SwiftGit2 未包装这部分）

    private func repositoryIsDirty(_ repo: OpaquePointer) -> Bool {
        var opts = git_status_options()
        git_status_init_options(&opts, UInt32(GIT_STATUS_OPTIONS_VERSION))
        opts.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        opts.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue

        var list: OpaquePointer?
        guard git_status_list_new(&list, repo, &opts) == 0, let list = list else {
            return false
        }
        defer { git_status_list_free(list) }
        return git_status_list_entrycount(list) > 0
    }

    private func stashSave(_ repo: OpaquePointer, message: String) throws {
        var sig: UnsafeMutablePointer<git_signature>?
        if git_signature_default(&sig, repo) != 0 {
            _ = git_signature_now(&sig, "GitSync", "gitsync@local")
        }
        guard let signature = sig else {
            throw GitServiceError.stashFailed("无法创建 git signature")
        }
        defer { git_signature_free(signature) }

        var oid = git_oid()
        let flags = GIT_STASH_INCLUDE_UNTRACKED.rawValue
        let status = git_stash_save(&oid, repo, signature, message, flags)
        guard status == 0 else {
            throw GitServiceError.stashFailed("git_stash_save 返回 \(status)")
        }
    }

    private func stashPop(_ repo: OpaquePointer) throws {
        var opts = git_stash_apply_options()
        git_stash_apply_init_options(&opts, UInt32(GIT_STASH_APPLY_OPTIONS_VERSION))
        opts.flags = GIT_STASH_APPLY_DEFAULT

        let status = git_stash_pop(repo, 0, &opts)
        guard status == 0 else {
            // 冲突或其他失败：stash 保留在列表里，不 drop，交给用户手动处理
            throw GitServiceError.stashPopConflict("git_stash_pop 返回 \(status)")
        }
    }

    // MARK: - 底层辅助：带认证的 fetch + fast-forward（SwiftGit2 自带的 fetch 不支持认证，这里手写）

    private func authenticatedFetchAndFastForward(localFolder: URL, branch: String, token: String) throws {
        var repoPtr: OpaquePointer?
        guard git_repository_open(&repoPtr, localFolder.path) == 0, let repo = repoPtr else {
            throw GitServiceError.notARepo
        }
        defer { git_repository_free(repo) }

        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repo, "origin") == 0, let remotePtr = remote else {
            throw GitServiceError.fetchFailed("找不到 origin 远程")
        }
        defer { git_remote_free(remotePtr) }

        CurrentAuth.username = "x-access-token"
        CurrentAuth.password = token

        var fetchOpts = git_fetch_options()
        git_fetch_init_options(&fetchOpts, UInt32(GIT_FETCH_OPTIONS_VERSION))
        fetchOpts.callbacks.credentials = gitSyncCredentialsCallback

        let fetchStatus = git_remote_fetch(remotePtr, nil, &fetchOpts, nil)
        guard fetchStatus == 0 else {
            throw GitServiceError.fetchFailed("git_remote_fetch 返回 \(fetchStatus)")
        }

        // 找远程分支最新的 commit
        var remoteRefPtr: OpaquePointer?
        let remoteRefName = "refs/remotes/origin/\(branch)"
        guard git_reference_lookup(&remoteRefPtr, repo, remoteRefName) == 0, let remoteRef = remoteRefPtr else {
            throw GitServiceError.fetchFailed("找不到远程分支引用 \(remoteRefName)")
        }
        defer { git_reference_free(remoteRef) }
        guard let targetOidPtr = git_reference_target(remoteRef) else {
            throw GitServiceError.fetchFailed("远程分支引用没有目标 commit")
        }
        var targetOid = targetOidPtr.pointee

        // 把本地分支引用强制指向远程最新 commit（fast-forward）
        let localRefName = "refs/heads/\(branch)"
        var newLocalRefPtr: OpaquePointer?
        let updateStatus = git_reference_create(&newLocalRefPtr, repo, localRefName, &targetOid, 1, nil)
        guard updateStatus == 0, let newLocalRef = newLocalRefPtr else {
            throw GitServiceError.fetchFailed("更新本地分支引用失败，返回 \(updateStatus)")
        }
        defer { git_reference_free(newLocalRef) }

        // 把 HEAD 挂到这个分支上（保持在分支上而不是 detached HEAD）
        let setHeadStatus = git_repository_set_head(repo, localRefName)
        guard setHeadStatus == 0 else {
            throw GitServiceError.fetchFailed("git_repository_set_head 返回 \(setHeadStatus)")
        }

        // 用新的 HEAD 内容更新工作目录
        var checkoutOpts = git_checkout_options()
        git_checkout_init_options(&checkoutOpts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        checkoutOpts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
        let checkoutStatus = git_checkout_head(repo, &checkoutOpts)
        guard checkoutStatus == 0 else {
            throw GitServiceError.fetchFailed("git_checkout_head 返回 \(checkoutStatus)")
        }
    }
}
