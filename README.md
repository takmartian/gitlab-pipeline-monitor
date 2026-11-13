# GitLab Pipeline Monitor

原生 macOS 菜单栏应用：在菜单栏看 GitLab 打星项目的流水线状态。
**SwiftUI + AppKit 手写，没有 Electron / Tauri / 任何第三方依赖。**

## 功能

- **菜单栏图标**：三节点流水线图形（SF Symbol 模板图标，自动适配明暗菜单栏）；可选状态圆点 + 失败数量。
- **点图标即看面板**：按项目分组列出打星项目的最新流水线 —— 分支、提交、耗时、覆盖率、触发人、相对时间、状态色。
- **筛选与搜索**：全部 / 运行中 / 失败 / 成功 / 其他（带计数），搜索匹配项目、分支、SHA。
- **流水线操作**：重跑、取消；点进详情页看阶段与作业列表，可重跑 / 取消单个作业、打开作业日志。
- **运行新流水线**：选分支或标签后触发（分支列表来自 GitLab API，默认选中默认分支）。
- **设置**：服务器地址 + 令牌（个人访问令牌 / OAuth 两种头），测试连接（返回用户、GitLab 版本、项目数），
  重新拉取项目列表，仅监控星标 / 手动勾选项目，每个项目显示的流水线数。
- **令牌加密存本机**（AES-GCM），按服务器主机名分账户，切换实例互不覆盖，不落配置文件、也不会弹钥匙串授权框。
- **自动刷新**：从不 / 30s / 1 / 2 / 5 / 10 分钟；打开面板时可自动刷新；右键菜单栏图标可暂停。
- **系统通知**：流水线失败、失败后恢复时通知（只在状态真的变化时通知，不会每次刷新都弹）。
- **其他**：开机自启（SMAppService）、中英文（跟随系统或手动）、面板宽度可调、改动即时生效无需保存。
- **快捷键**：⌘, 设置、⌘R 刷新、⌘W 关闭设置、⌘Q 退出；输入框支持 ⌘V/⌘C/⌘X/⌘A
  （accessory 应用必须自建主菜单，否则文本框里粘贴会没反应 —— 已处理）。

## 使用

1. 打开 App，点菜单栏图标，再点齿轮（或右键图标 - 设置）。
2. 填服务器地址（如 https://gitlab.example.com，误带 /api/v4 会自动去掉）和令牌。
   令牌需要 read_api 权限；要读取你没加入的项目再加 read_user。
3. 点「测试连接」确认，然后「重新拉取项目列表」。
4. 之后点菜单栏图标就能看流水线；默认监控你打过星的项目。

令牌为什么不放钥匙串：本 App 是 ad-hoc 签名（没有 Apple 证书），而 macOS 的钥匙串按「分区 ID」认人，
非 Apple 签名程序的分区 ID 就是它的 cdhash —— 每重新构建一次 cdhash 就变一次，于是每换一个构建都要重新
授权一次（弹密码框）。所以令牌改为存 `~/Library/Application Support/GitLab Pipeline Monitor/tokens.json`，
用 AES-GCM 加密，密钥 = SHA256(前缀 + 本机硬件 UUID + 登录用户名 + 每条随机 salt)，密钥本身不落盘。

## 构建

    ./build.sh                    # release，产物在 build/GitLab Pipeline Monitor.app
    ./build.sh debug              # debug 版
    ./build.sh release --dist     # 额外产出 dmg / zip（内含「安装.command」与安装说明）
    ./build.sh release --notarize # 有 Developer ID 证书时：签名 + hardened runtime + 公证 + staple

要求 macOS 14+ 与 Xcode 工具链（脚本会自己设 DEVELOPER_DIR）。图标由 Tools/make_icon.swift 生成后用 iconutil 打包。

## 分发给别人

App 用 ad-hoc 签名、未做 Apple 公证，所以**别人从网上/微信/网盘下载后直接双击**，
Gatekeeper 会拦（`spctl -a` 判定为 rejected），提示通常是：

> 「GitLab Pipeline Monitor」已损坏，无法打开。你应该将它移到废纸篓。

这不是文件坏了，是「未公证 + 带 quarantine 隔离属性」的组合。三种解法（dmg 与 zip 内都附了
`安装.command` 和 `安装说明.txt`）：

1. **双击 dmg 里的「安装.command」**：自动拷到 /Applications、去掉隔离属性、启动。
   首次双击若提示无法验证开发者，改为右键 → 打开。
2. **手动拖拽 + 一行命令**：拖到「应用程序」后执行
   `xattr -dr com.apple.quarantine "/Applications/GitLab Pipeline Monitor.app"`。
3. **上 Apple Developer ID 证书**（$99/年）：`./build.sh release --notarize`，
   签名换成 Developer ID + hardened runtime 并做公证 staple，之后任何人下载都能直接双击。

自己本机编译运行不会有这个问题（本地产出的文件没有隔离属性）。

## 开发自检（不需要录屏权限）

    B="build/GitLab Pipeline Monitor.app/Contents/MacOS/GitLabPipelineMonitor"
    "$B" --selftest https://gitlab.example.com <token>   # 命令行自检：用户 / 版本 / 星标项目 / 流水线
    "$B" --demo                                           # 用假数据把面板弹出来预览
    "$B" --snapshot /tmp/panel.png /tmp/settings.png      # 离屏渲染面板与设置窗口成 PNG
    "$B" --snaptab connection|projects|general|about      # 单独渲染某个设置标签页
    "$B" --snapdetail                                     # 渲染流水线详情页
    "$B" --tokencheck                                     # 检查加密令牌文件（权限/机器指纹/可否解密）
    "$B" --diag                                           # 连接诊断：账号/版本/项目/每项目流水线条数

## 目录

    Sources/GitLabPipelineMonitor/
      main.swift / AppController.swift / MenuBarController.swift   生命周期与菜单栏
      GitLabClient.swift / Models.swift / TokenStore.swift         API、模型、加密令牌存储
      AppSettings.swift / AppState.swift / Notifier.swift          设置、状态、通知
      Views/                                                       面板、详情、运行、设置
      DemoData.swift / Snapshot.swift                              演示数据与离屏渲染
    Tools/make_icon.swift                                          图标生成
    Resources/Info.plist                                           LSUIElement 等
