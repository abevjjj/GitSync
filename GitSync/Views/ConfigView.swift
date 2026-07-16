import SwiftUI
import UniformTypeIdentifiers

struct ConfigView: View {
    var onSaved: (RepoConfig) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var remoteURLString = ""
    @State private var branch = "main"
    @State private var token = ""
    @State private var pickedFolder: URL?
    @State private var showingPicker = false
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let gitService = GitService()

    var body: some View {
        NavigationStack {
            Form {
                Section("仓库信息") {
                    TextField("名称（随便填，仅展示用）", text: $displayName)
                    TextField("仓库地址 https://github.com/user/repo.git", text: $remoteURLString)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("分支", text: $branch)
                    SecureField("GitHub Personal Access Token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("本地存储位置") {
                    Button {
                        showingPicker = true
                    } label: {
                        if let pickedFolder {
                            Label(pickedFolder.lastPathComponent, systemImage: "folder.fill")
                        } else {
                            Label("选择「文件」App 中的位置（建议 iCloud 云盘）", systemImage: "folder")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建同步配置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("完成") { save() }
                            .disabled(!formValid)
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                FolderPicker { url in
                    pickedFolder = url
                }
            }
        }
    }

    private var formValid: Bool {
        !remoteURLString.isEmpty && !branch.isEmpty && !token.isEmpty && pickedFolder != nil
    }

    private func save() {
        guard let folder = pickedFolder, let remoteURL = URL(string: remoteURLString) else { return }
        isWorking = true
        errorMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bookmark = try BookmarkStore.makeBookmark(for: folder)

                // 首次配置：如果目标文件夹里还不是 git 仓库，就 clone；
                // 如果已经是（比如用户之前手动 clone 过），就直接复用。
                if !gitService.isExistingRepo(at: folder) {
                    try gitService.clone(remoteURL: remoteURL, to: folder, branch: branch, token: token)
                }

                let name = displayName.isEmpty
                    ? (remoteURL.lastPathComponent.replacingOccurrences(of: ".git", with: ""))
                    : displayName

                let config = RepoConfig(
                    remoteURLString: remoteURLString,
                    branch: branch,
                    bookmarkData: bookmark,
                    displayName: name
                )
                KeychainHelper.saveToken(token, forConfigId: config.id)
                RepoConfigStore.add(config)

                DispatchQueue.main.async {
                    isWorking = false
                    onSaved(config)
                    dismiss()
                }
            } catch {
                DispatchQueue.main.async {
                    isWorking = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

/// 包一层 UIDocumentPickerViewController，选目录而不是文件
struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

#Preview {
    ConfigView(onSaved: { _ in })
}
