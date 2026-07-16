# GitSync

个人使用的 iOS App：把 GitHub 仓库同步到「文件」App / iCloud 云盘中你手动选择的位置，
支持完整 git 操作（clone / 保留本地未提交修改的 pull / commit+push），一次配置长期复用。

## 目录结构

```
GitSync/
├── project.yml              # XcodeGen 项目描述（CI 会据此生成 .xcodeproj，你不需要手动建工程）
├── .github/workflows/
│   └── build-ipa.yml         # GitHub Actions：云端 macOS 编译，产出未签名 .ipa
└── GitSync/
    ├── App.swift
    ├── Info.plist
    ├── Models/RepoConfig.swift        # 仓库配置的数据结构与本地存取
    ├── Services/KeychainHelper.swift  # PAT 存 Keychain
    ├── Services/BookmarkStore.swift   # 手动选择的文件夹 -> security-scoped bookmark
    ├── Services/GitService.swift      # clone / stash-pull-pop / commit+push 核心逻辑
    └── Views/ContentView.swift, ConfigView.swift
```

## 整体流程（你完全不需要 Mac）

```
[Windows/Linux 电脑] 改代码、git push
        ↓
[GitHub Actions 云端 macOS runner] 自动跑 xcodebuild，产出 GitSync-unsigned.ipa
        ↓  下载 artifact 到本地
[Windows/Linux 电脑 + Sideloadly] 用免费 Apple ID 给 ipa 签名，USB 连 iPhone 安装
        ↓
[你的 iPhone] 装上 GitSync
```

## 第一步：把这个项目推到你自己的 GitHub 仓库

```bash
cd GitSync
git init
git add -A
git commit -m "init GitSync"
git branch -M main
git remote add origin https://github.com/<你的用户名>/GitSync-app.git
git push -u origin main
```

推送后，GitHub 会自动跑 `.github/workflows/build-ipa.yml`（也可以在仓库的 Actions 页面手动点 "Run workflow"）。
跑完之后，在该次 workflow run 的页面底部 "Artifacts" 里下载 `GitSync-unsigned-ipa`，解压得到 `GitSync-unsigned.ipa`。

## 第二步：在 Windows/Linux 上用 Sideloadly 签名安装

1. 电脑上安装 [Sideloadly](https://sideloadly.io/)（Windows 和部分 Linux 发行版都支持，Linux 上一般通过其提供的方式运行，具体看官网下载页）
2. 用 USB 连接 iPhone，信任电脑
3. 打开 Sideloadly，把下载好的 `GitSync-unsigned.ipa` 拖进去
4. 登录你的 **免费 Apple ID**（不需要付费开发者账号）
5. 点击开始，Sideloadly 会自动完成签名 + 安装
6. 首次打开 App 前，去 iPhone「设置 → 通用 → VPN与设备管理」，信任这个开发者证书

⚠️ **免费 Apple ID 签名的限制**：App 装上后 **7 天会过期**，届时需要重新用 Sideloadly 签一次（不需要重新编译，只要重新走一遍"拖 ipa → 签名安装"，几分钟搞定）。如果不想每周弄一次，后续可以升级到 $99/年的 Apple Developer Program 账号，那样证书有效期是一年。

## 第三步：App 内配置（只需一次）

1. 打开 App，点右上角 "+"
2. 填仓库地址（如 `https://github.com/user/repo.git`）、分支（如 `main`）
3. 填 GitHub Personal Access Token（建 fine-grained token，只给这个仓库的 Contents 读写权限即可，GitHub 设置路径：Settings → Developer settings → Personal access tokens → Fine-grained tokens）
4. 点"选择本地存储位置"，在弹出的"文件"选择器里，选 iCloud 云盘下你想要的文件夹（也可以是本地"我的 iPhone"下的文件夹）
5. 点"完成"，App 会自动执行首次 clone，把仓库内容写入你选的文件夹

配置完成后，主界面上这个仓库会一直显示，之后只需要点"下载"/"上传"两个按钮。

## 关于"下载"和"上传"具体做了什么

- **下载**：如果本地有未提交的修改，先 `git stash`，然后 fetch 远程并把当前分支快进到最新，最后尝试 `git stash pop` 把你的修改放回来。
  - 如果 pop 时发生冲突，App 会提示你，此时修改**不会丢失**，仍保存在 git 的 stash 列表里，需要你后续手动用 git 命令行（或以后版本加的冲突处理 UI）解决。
- **上传**：`git add -A` + `commit`（自动生成时间戳提交信息）+ `push` 到当前分支。
  - 如果远程有你本地没有的新提交，push 会被拒绝，此时提示你先"下载"一次再重试（当前版本不做自动 rebase/merge 的复杂处理，避免个人工具引入不必要的冲突逻辑）。

## ⚠️ 关于代码成熟度的坦诚说明

这套代码是在**没有 macOS/Xcode 环境**的情况下写就的（我只能在 Linux 容器里写文本，无法在本地实际编译 Swift/iOS 代码验证）。结构和逻辑是对的，但推送到 GitHub 后，第一次跑 Actions 大概率会遇到一些需要小修的地方，最可能出问题的位置：

1. **`GitService.swift` 里 `git_stash_*` 相关的 libgit2 C API 调用**——libgit2 不同版本这块函数签名/常量名有细微差异（如 `GIT_STASH_APPLY_OPTIONS_VERSION` 的宏定义方式），如果编译报错，把报错信息发我，我照着改。
2. **`Repository.commit(...)` 的参数签名**——SwiftGit2 该 API 在不同版本间变化过，如果报"找不到该方法/参数不匹配"，需要对照你实际拉到的 SwiftGit2 版本调整。
3. **`repo.checkout` / `repo.fetch` / `repo.push` 的方法签名**同理，SwiftGit2 是一个仍在演进中的库，`project.yml` 里锁的是 `main` 分支，如果想要更稳定，可以改成锁某个 tag。

修法很简单：把 CI 报错的完整日志贴给我，我按照报错逐个调整对应的 Swift 代码就行，这类"编译期签名不匹配"的问题不涉及架构改动。

## 后续可以加的功能（当前版本暂未做）

- 冲突处理 UI（目前冲突只是提示，不提供图形化合并界面）
- 分支切换 / 新建分支
- commit 历史查看
- 多仓库同时批量同步
- 后台自动同步（受 iOS 后台执行限制，做不到实时，只能做"打开 App 时自动检查"或"配合服务器 webhook 推送触发"）

## 许可证注意

SwiftGit2 / libgit2 是 GPL-2.0-with-linking-exception 许可，个人使用没有问题；如果以后考虑上架 App Store 分发给别人用，需要留意开源许可证的合规要求。
