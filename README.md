# Hermes Light for Windows

使用 [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) 自带的 **Light** 模式，构建 Windows x64 便携客户端。本仓库只负责构建和分发，不修改上游源码；它不是 Nous Research 官方发行版。

## 构建方式

核心命令在上游仓库根目录执行：

```powershell
$env:HERMES_DESKTOP_VARIANT = 'light'
npm ci --workspace apps/desktop --workspace apps/shared --include-workspace-root --engine-strict --no-audit --no-fund
npm run pack --workspace apps/desktop
```

安装和打包规则由上游维护。这里不补装缺失依赖、不裁剪产物、不重命名 EXE，也不调用上游 Electron 内部 API。使用完整的浅检出，避免维护 sparse checkout 的目录清单。

`build.ps1` 将上述步骤串起来，并检查产物的 `payload: light`、提交 SHA、干净源码标记、EXE 和 ASAR，以及没有 bundled Agent payload。随后添加许可证和构建信息，生成 ZIP 和 SHA256。

## 本地构建

需要 Windows x64、PowerShell 7、Git，以及符合上游 `engines` 的 Node/npm。CI 使用 Node 22 的最新补丁版本；依赖安装启用 `--engine-strict`。

```powershell
# 最新正式 release，也可以指定 -Version vX.Y.Z
.\build.ps1

# 上游 main；可用 -UpstreamCommit 指定完整 SHA
.\build.ps1 -Version main
```

输出位于 `dist`：`Hermes-Light-<上游tag或nightly日期与SHA>-win-x64.zip`、对应 `.sha256` 和 `BUILD-INFO.json`。每次使用新的 `.build/<id>` 检出目录，不复用旧产物，也不覆盖同名 ZIP。完成后可以自行删除 `.build` 以回收磁盘空间。

## 自动构建和发布

Actions → **Build Windows Light** → **Run workflow**：Version 留空选择最新正式 release，填写正式 tag 构建指定版本，填写 `main` 构建 Nightly。

- 北京时间每天 11:23 检查最新正式版。
- 北京时间每天 00:00 构建 main 的 Nightly，日期使用北京时间。
- 构建前固定上游提交；已有同名 Release 时跳过。正式版 Release tag 为 `light-<上游tag>`，Nightly 为 `light-nightly-YYYYMMDD-<12位SHA>`，避免与历史 Thin Client 混淆。
- Nightly 以预发布形式发布，不替代正式版 Latest。
- 构建 job 只有读取权限；发布 job 校验 SHA256 后创建 draft、上传附件并公开。失败时可能留下 draft，需处理后重试。

两种版本共用同一流程。Actions 固定到提交 SHA。上游自身构建失败时，本项目也会失败，不增加针对某次上游变动的兼容补丁。

向 `main` 推送构建脚本或工作流变更时，也会自动构建最新正式版；已有同名 Release 时仍跳过。

## 使用和验证范围

从 Releases 下载 ZIP 和 SHA256，完整解压到可写目录，运行 `BUILD-INFO.json` 中记录的 EXE。客户端身份、配置路径、连接界面和运行行为都使用上游 Light 的实现。Windows Light 使用外部更新机制：退出客户端后下载并替换整个程序目录。

旧 Thin Client 的 `%APPDATA%\HermesThin` 自定义配置路径及启动脚本不再使用；新版本按上游默认路径管理配置，需要重新配置连接。

CI 检查构建成功、Light 标记、提交一致性和 ZIP 完整性，不测试真实网关登录/聊天，也不宣称所有 Local 入口均已被上游屏蔽。Electron、原生依赖和其他随包文件由上游打包规则决定。未签名的自行构建 EXE 可能显示 Unknown Publisher。
