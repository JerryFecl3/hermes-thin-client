# Hermes Light for Windows

使用 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) 自带的 **Light** 模式，构建 Windows x64 便携客户端。本仓库只负责构建和分发，不修改上游源码；它不是 Nous Research 官方发行版。

## 构建方式

核心命令在上游仓库根目录执行：

```powershell
$env:HERMES_DESKTOP_VARIANT = 'light'
node scripts/build/node-deps.mjs --source (Get-Location).Path --workspace apps/desktop
pnpm --dir apps/desktop run pack
```

安装和打包规则由上游维护。所选提交的 `node-deps.mjs` 负责锁定安装 Desktop 及其工作区依赖、核对 pnpm 并准备 Electron。这里不重复维护安装参数、不补装缺失依赖、不裁剪产物、不重命名 EXE，也不调用 Electron 包的内部 API。使用完整的浅检出，避免维护 sparse checkout 的目录清单。

`build.ps1` 将上述步骤串起来，并检查产物的 `payload: light`、提交 SHA、干净源码标记、EXE 和 ASAR，以及没有 bundled Agent payload。随后添加许可证和构建信息，生成 ZIP 和 SHA256。

## 本地构建

需要 Windows x64、PowerShell 7、Git。先安装所选上游提交的 `pm/lock.json` 中 `packages.node.version`、`packages.npm.version`，以及存在时的 `packages.pnpm.version` 指定的精确版本；`build.ps1` 会在安装依赖前核对实际版本，不符立即停止。

现代路径还需要原生 `pnpm.exe` 位于 PATH，只有 npm 的 `pnpm.cmd` shim 不够。通过 npm 全局安装 pnpm 时，将 `Join-Path (npm root --global) 'pnpm'` 指向的包目录加入本次构建进程的 PATH；CI 会完成这一步，并检查原生文件存在。

上游锁中包含 pnpm 时，使用上述上游依赖准备 CLI，安装范围和 engine 检查由上游配置决定。旧提交没有 pnpm pin 时，继续执行 `npm ci --workspace apps/desktop --workspace apps/shared --include-workspace-root --engine-strict --no-audit --no-fund` 和 `npm run pack --workspace apps/desktop`。pnpm pin 格式错误、版本不符或所选提交缺少 CLI 时明确失败，不会回退到 npm 或自行拼装依赖准备步骤。

CI 先解析正式 tag 或 main 的完整 SHA，再通过带认证的 GitHub Contents API 按该 SHA 读取工具链锁（最多重试 3 次，遵循 HTTP 429 的 Retry-After），安装精确 Node、npm 和需要的 pnpm，最后检出同一 SHA 并重新核对工具链。不会使用浮动 main 的锁构建旧 tag，不读取 `engines` 范围来猜测版本，也不回退到 latest。锁文件缺失、schema 不支持或版本不是精确的三段数字时会失败，需要维护者检查上游变化。

```powershell
# 最新正式 release，也可以指定 -Version vX.Y.Z
.\build.ps1

# 上游 main；可用 -UpstreamCommit 指定完整 SHA
.\build.ps1 -Version main
```

输出位于 `dist`：`Hermes-Light-<上游tag或nightly日期与SHA>-win-x64.zip`、对应 `.sha256` 和 `BUILD-INFO.json`。构建信息记录完整上游 SHA、实际 Node/npm/pnpm 版本、打包命令和工具链锁的 SHA256。每次使用新的 `.build/<id>` 检出目录，不复用旧产物，也不覆盖同名 ZIP。完成后可以自行删除 `.build` 以回收磁盘空间。

## 自动构建和发布

Actions → **Build Windows Light** → **Run workflow**：Version 留空选择最新正式 release，填写正式 tag 构建指定版本，填写 `main` 构建 Nightly。`validate_only` 默认勾选：完整构建并上传 Actions artifact，跳过已有 Release 检查，绝不创建或修改 Release。只有在 main 分支运行并取消勾选时才允许发布。

- 北京时间每天 11:23 检查最新正式版。
- 北京时间每天 00:00 构建 main 的 Nightly，日期使用北京时间。
- PR 自动验证上游 main 的 Windows Nightly，只上传 Actions artifact，不发布 Release。验证与发布使用同一个构建脚本和产物检查。
- 构建前固定上游提交；已有同名 Release 时跳过。正式版 Release tag 为 `light-<上游tag>`，Nightly 为 `light-nightly-YYYYMMDD-<12位SHA>`，避免与历史 Thin Client 混淆。
- Nightly 以预发布形式发布，不替代正式版 Latest。
- 构建 job 只有读取权限；发布 job 校验 SHA256 后创建 draft、上传附件并公开。失败时可能留下 draft，需处理后重试。

两种版本共用同一流程。Actions 固定到提交 SHA。上游自身构建失败时，本项目也会失败，不增加针对某次上游变动的兼容补丁。

向 `main` 推送构建脚本或工作流变更时，也会自动构建最新正式版；已有同名 Release 时仍跳过。

## 使用和验证范围

从 Releases 下载 ZIP 和 SHA256，完整解压到可写目录，运行 `BUILD-INFO.json` 中记录的 EXE。客户端身份、配置路径、连接界面和运行行为都使用上游 Light 的实现。Windows Light 使用外部更新机制：退出客户端后下载并替换整个程序目录。

旧 Thin Client 的 `%APPDATA%\HermesThin` 自定义配置路径及启动脚本不再使用；新版本按上游默认路径管理配置，需要重新配置连接。

CI 检查构建成功、Light 标记、提交一致性和 ZIP 完整性，不测试真实网关登录/聊天，也不宣称所有 Local 入口均已被上游屏蔽。Electron、原生依赖和其他随包文件由上游打包规则决定。未签名的自行构建 EXE 可能显示 Unknown Publisher。

## 工具链验证与旧版本

运行 `pwsh -File tests/toolchain.Tests.ps1` 检查锁文件解析、格式变化拒绝、不同版本 pin、锁摘要以及实际 Node/npm/pnpm 不匹配的处理，包含旧 npm 提交与新 pnpm 提交。`pwsh -File tests/build.Tests.ps1` 用隔离的命令替身检查新旧构建路径、失败停止和关键产物保护，不联网或安装依赖。Windows CI 也会执行这两组检查，并实际构建 Windows 包。构建摘要会记录精确上游 SHA、工具版本和通过的产物检查。

旧正式版只有在自身提交包含受支持的 `pm/lock.json` 时才能构建；缺锁的历史版本会明确失败，不继承新版本的工具链。即使锁可读取，上游构建入口、依赖或产物布局发生变化仍可能需要维护。本项目不会修改上游源码、补装依赖或关闭 engine-strict 来绕过这些问题。
