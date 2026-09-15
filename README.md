# 筑梦启动器 · ComfyUI 桌面版

面向 Windows ComfyUI 便携整合包的启动、网络配置、核心更新和扩展管理工具。

这是**启动器源码和补丁仓库**。不包含 Python 环境、模型、第三方节点或用户数据，不能单独当作完整 ComfyUI 安装包运行。

## 已有 1.3.0 包怎么升级

1. 在 [Releases](https://github.com/YuMir1688/zhumeng-comfyui-launcher/releases) 下载 `zhumeng-first-update-1.3.2.zip`。
2. 关闭 ComfyUI 和启动器，将补丁解压到原整合包根目录，与 `启动_ComfyUI.exe` 放在一起。
3. 双击 `Install-Launcher-Update.cmd`，完成后重新打开启动器。
4. 进入维护中心 → 版本更新 → **检查启动器更新**。之后可在线下载启动器补丁，无需重传整合包。

首次补丁包含离线安装材料。不要把源码 ZIP 当作升级补丁，也不要安装到模型目录。

## 1.3.4 同步修复

当前补丁是 1.3.4，包含网络异常闪退和核心更新 Get-FileHash 不可用修复。旧版使用 Release 中的 `zhumeng-first-update-1.3.4.zip`，解压至整合包根目录运行 `Install-Launcher-Update.cmd`。本版本只更新启动器与维护脚本。

## 1.3.3 紧急修复

修复 1.3.2 网络失败导致整个启动器退出的问题。旧版无法保持打开时，请使用 Release 中的 `zhumeng-first-update-1.3.3.zip`，解压到原包根目录运行 `Install-Launcher-Update.cmd`。详见 [1.3.3 验证记录](docs/validation-1.3.3.md)。

## 两种更新

- **启动器更新**：更新此仓库发布的启动器文件。开启自动检查时，启动后检查新版本；用户确认后才安装。下载完成后需要关闭主启动器。
- **ComfyUI 核心更新**：下载 ComfyUI 官方源码，解析依赖，预备新旧依赖文件，切换核心并执行隔离启动检查；失败时恢复。

启动器补丁有整包及逐文件 SHA-256 校验、路径检查、安装备份和失败恢复。备份在 `.cache/launcher-backup-*`。

## 1.3.2 修复

- 修复 `av>=16.0.0` 等范围依赖被误当成不可回滚版本的问题。
- 从已安装环境获取精确回滚版本。实际版本满足新版要求时无需重装 av。
- av 确实需要变更时，先下载目标和回滚 wheel，再安装。
- 保留显卡运行时依赖保护；并非任意依赖变更都会被自动放行。
- 回滚失败时保留核心更新的离线恢复材料。
- 增加启动器在线更新入口和启动时版本提示。
- 修复日志导出选择文件夹时的错误处理。
- 修正 EXE 文件版本与界面版本不一致，并在构建和安装时验证版本一致性。1.3.1 为被替代的预发布版本。

## 兼容范围与验证边界

目标系统是 Windows 10/11 x64，使用系统 Windows PowerShell 5.1 和 .NET Framework 的桌面界面。GPU 面向 RTX 30/40/50 系列；需要与显卡和整合包 CUDA 环境兼容的 NVIDIA 驱动。系统管理策略若禁止 PowerShell，桌面启动器无法启动，需由管理员处理；包内 `tools/启动_ComfyUI_通用.bat` 可作为另一个启动入口。

2026-09-15 的实际测试环境：Windows 11 x64、RTX 5070 Ti、驱动 595.97、PyTorch 2.11.0+cu128。核心更新的隔离启动测试使用 CPU 模式并关闭第三方节点。

**没有宣称所有显卡、Windows 版本和第三方节点组合均已实测。** 完整记录见 [验证报告](docs/validation-1.3.1.md)。升级核心不能保证每个第三方节点兼容新核心。

网络使用启动器的代理设置，自动下载模式会尝试 GitHub 和备用加速通道。离线安装补丁无需联网；在线更新仍需要至少一个下载通道可达。哈希校验用于检查文件一致性，不等同于 Windows 代码签名。

## 开发和构建

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Patch.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-LauncherPatch.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\launcher\tools\ComfyUI-Core-Updater.ps1 -SelfTest
```

输出位于 `dist`。`launcher-update.json` 与相应 ZIP 必须一起发布为非预发布 Release。发布前必须在**独立整合包副本**中测试，不要用学员工作目录运行破坏性故障注入测试。

`Test-CoreRollback.ps1 -Root <测试副本>` 要求副本核心已更新到 0.35.0，会故意尝试切换到 0.33.1 后注入失败，验证核心和依赖完整恢复。`Test-AvMigration.ps1 -Root <测试副本>` 会实际切换 av 到 17.0.0 再恢复。

## 问题反馈

请提供 Windows 版本、显卡型号、驱动版本、启动器版本和脱敏后的运行日志。不要上传 Token、账号信息、私人工作流和完整整合包。

本项目不是 ComfyUI 官方桌面应用。ComfyUI 名称和图标属于其相应权利人；第三方组件保持原有许可。本仓库的公开可见性本身不授予额外的第三方素材使用权。
