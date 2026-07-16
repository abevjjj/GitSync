import Foundation

enum BookmarkError: Error {
    case cannotCreate
    case staleBookmark
    case cannotAccess
}

enum BookmarkStore {
    /// 用户在 UIDocumentPickerViewController 里选完文件夹后，立刻调用这个把权限"固化"下来
    static func makeBookmark(for url: URL) throws -> Data {
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.cannotAccess
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            return try url.bookmarkData(
                options: [], // iOS 上不用 .withSecurityScope（那是 macOS 的选项）
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            throw BookmarkError.cannotCreate
        }
    }

    /// 每次真正要读写这个文件夹前，先 resolve 出 URL，
    /// 用完之后调用方必须调用 url.stopAccessingSecurityScopedResource()
    static func resolve(_ bookmark: Data) throws -> URL {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard url.startAccessingSecurityScopedResource() else {
            throw BookmarkError.cannotAccess
        }
        if isStale {
            // 依然可用，但建议上层在下次操作后重新生成一次 bookmark 替换掉旧的
            print("⚠️ bookmark is stale，建议重新选择一次文件夹")
        }
        return url
    }
}
