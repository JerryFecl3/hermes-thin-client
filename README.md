# Hermes Windows Thin Client

非官方 Windows x64 构建工具链，使用 **未修改的 NousResearch/hermes-agent Desktop 源码**生成可解压运行的 Remote Gateway 客户端。

## 下载和使用

在本仓库 Releases 下载 `Hermes-ThinClient-<tag>-win-x64.zip` 和 `.sha256`。
完整解压到任意可写目录，运行 **Start-Hermes.cmd**，选择 **Connect to existing Hermes / Remote Gateway**，填写你自己的网关地址并在界面中认证。

客户端不包含 Hermes Agent、Python/venv/uv、Git、独立 Node/npm、ffmpeg.exe 或 Playwright 浏览器。Electron 内嵌 Chromium、V8、Node，以及必要的 ffmpeg.dll；官方 staged native dependencies 保留 node-pty 和 get-windows。上游 Local 模式 UI 仍然存在，本项目不对其进行功能删改；请使用 Remote Gateway。

配置位于 `%APPDATA%\HermesThin`，不在程序目录内。升级时退出客户端（包括托盘），替换程序文件，继续使用启动脚本；不要删除配置目录。内置源码式 updater 不受支持。

## 自动构建

- Actions → **Build Windows Thin Client** → **Run workflow**：Version 留空构建最新正式 release，也可填写正式 tag。
- 每天 UTC 03:23 检查一次上游正式 release；已有同名 Release 时跳过构建。
- 使用标准 Windows 2022 runner 和固定 Node 22.23.2。Node/npm 会按上游 engines 校验。
- sparse checkout 只展开 `apps/desktop`、`apps/shared` 和根目录文件；保留 Git 元数据用于 stamp。
- 构建、包审计和真实 Electron 模拟网关测试全部通过后，发布 ZIP、SHA256 和 BUILD-INFO。
- 构建 job 只有仓库读取权限；发布 job 单独获得写权限。不需要 PAT 或 Remote Gateway secrets。
- 自动版本选择不保证未来上游构建兼容；失败时不会发布可见 Release。若发布上传途中失败留下 draft，请检查并删除失败 draft 后重试。
- GitHub 公开仓库的标准托管 runner 计算免费；定时任务可能延迟，公开仓库 60 天无活动时 schedule 会停用。Artifacts 保留 7 天，正式下载使用 Releases。

Action 依赖固定到提交 SHA。可以在 Actions 查看每次构建日志和确切上游版本。这里的自动化不是客户端后台自更新；用户自行下载替换。

## 本地构建

Windows x64、Git、符合上游要求的 Node/npm 和网络连接：

```powershell
.\build.ps1 -Version v2026.9.11
.\package.ps1
```

省略 Version 选择最新正式 release。输出位于 `dist`；脚本拒绝覆盖同名 ZIP，请先归档旧文件。
支持将官方便携 Git 和 Node 放在 `tools/git`、`tools/node`，脚本自动优先使用，或者传 `-NodeDirectory`。便携工具及缓存不提交仓库、不进入客户端 ZIP。没有这些目录时使用 PATH 中的工具。

`deploy.ps1 -ZipPath <zip>` 默认部署到 `C:\Apps\HermesThin`，以普通目录移动保留旧版；`-Rollback` 回滚。它拒绝覆盖非托管的非空目录，不删除用户配置。`-ForceClose` 仅在需要强制关闭该部署路径的客户端时使用。

## 验证范围和已知问题

CI 对 ZIP 中的 Windows EXE 进行隔离首次启动、模拟 HTTP/WebSocket 连接、保存连接后重启以及配置保留检查，并审计禁止的本地 runtime 文件。GitHub runner 自带多种开发工具，因此这不等同于干净 Windows VM 验收；真实私有网关的登录/聊天也不在 CI 中测试。

首次登录超过约 45 秒可能触发上游的 94% 卡住问题：连接保存后彻底退出并重启。未为此修改上游源码。未来上游修复后应重新验证。

自行构建 EXE 没有 Nous 的签名，可能显示 Unknown Publisher。请核对下载来源和 SHA256。

本项目不是 Nous Research 官方发行版。上游许可证随客户端以 `LICENSE.hermes.txt` 分发；Electron 自带许可证文件保留。构建脚本不会携带任何真实连接地址、用户数据或凭据。
