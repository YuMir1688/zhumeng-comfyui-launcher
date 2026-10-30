# 1.3.8 核心依赖迁移验证

验证日期：2026-10-30。环境：Windows、Windows PowerShell 5.1、便携 Python 3.11.6、pip 25.2、PyTorch 2.11.0+cu128。真实更新使用独立整合包副本，不改动分发包的 0.33.1 核心。

联网测试使用 GitHub 官方源码、PyPI 官方源及本机已配置的 HTTP 代理。这不代表学员的直连网络已通过测试。正常升级轮次虽提供已校验的本地 wheel 候选目录，但 pip 仍优先选择网络下载，未据此宣称缓存加速成功。

## 原因与修复

原更新器要求新旧 requirements.txt 的包名集合完全一致。实际 0.33.1 基线有 35 项、0.43.0 目标有 34 项，后者不再声明 torchaudio，因此被直接拦截。Pillow 的约束变化也会触发原先过宽的底层依赖限制。

修复后复用已有依赖修复事务：对完整目标 requirements 做预检，从已安装环境记录旧版本，缓存并校验目标和回滚 wheel。新增包记录到回滚清单；移除的声明不会导致卸载共享包。Torch、CUDA 等运行时保护保留。

真实下载测试还发现 Windows PowerShell 5.1 将 JSON 数组作为单个管道对象返回，导致多文件清单计数错误。现已展开数组，并增加多目标文件和回滚文件的回归用例。

## 已验证

| 检查 | 证据 |
|---|---|
| 更新器自检 | `ComfyUI-Core-Updater.ps1 -SelfTest` 返回 `Result: OK`；新增依赖、移除声明保留、显卡运行时保护、核心回滚、用户数据保护、目录穿越、多文件哈希校验通过 |
| 新增包的实际回滚 | `Test-AddedDependencyRollback.ps1` 安装本地合成 wheel，再执行生产回滚函数；输出 `PASS: actual new wheel installed, rolled back without old wheels, all distribution versions unchanged` |
| 后台日志与哈希 | `Test-CoreHash.ps1`、指定便携 Python 的 `Test-BackgroundPython.ps1`、`Test-UpdateLiveProgress.ps1` 通过；首次误用系统 Python 的日志测试失败，改用已核验便携 Python 后通过 |
| 1.3.8 补丁 | `Build-Patch.ps1` 生成补丁；`Test-LauncherPatch.ps1` 返回四项 `OK`，覆盖安装、中文空格路径、文件占用回滚和错误哈希拦截，并检查模型、扩展、工作流、输入输出和核心哨兵文件不变 |
| 实际核心升级后的故障回滚 | `Test-Core043Migration.ps1 -InjectFailure` 返回 `Result: OK`、`InventoryRestored: true`、`ExtensionsUnchanged: true`。从官方在线下载源码和依赖，实际替换 8 个包并新增 1 个包；0.43.0 隔离启动检查成功后注入失败，恢复原核心入口文件哈希及全部 Python 发行包版本，扩展顶层目录记录不变。证据日志：`core043-08d63097fac74b9f9e397d06a1a275ed.log` |
| 正常升级 0.33.1 → 0.43.0 | `Test-Core043Migration.ps1` 返回 `Result: OK`、`InjectedFailure: false`、`ExtensionsUnchanged: true`；状态记录 `success: true`。核心版本文件与隔离启动输出均确认为 0.43.0；原有 torch、torchvision、torchaudio 等运行包版本不变。证据日志：`core043-ae6aff06410840558021b488eb7d3863.log`，18:31:45 显示更新成功 |
| 0.43.0 网页服务与无模型工作流 | `Test-Core043HTTP.py` 返回 `core: 0.43.0`、`http: OK`、`modelFreeWorkflow: OK`；实际启动 CPU 服务，访问 `/system_stats`，提交 `EmptyImage → SaveImage`，任务完成并输出 64×64 PNG。输入输出均在独立临时目录，关闭全部第三方节点。证据目录：`core043-http-lnjjw2ma` |
| 本地启动器同步与自检 | 独立核验副本和本地分发目录均安装 1.3.8；分发目录的 `comfyui_version.py` 仍为 0.33.1。核验副本的 `ComfyUI-Launcher.ps1 -SelfTest` 返回 `Result: OK`、131 个控件、`CoreUpdater: Verified`、`ExtensionWorker: Verified` |

## 未验证

- 学员电脑、所有显卡驱动、所有自定义节点和模型工作流组合。
- 断电、强制结束更新进程后的自动恢复；本次回滚测试针对可捕获的更新失败。
- 不保证无法联网时在线更新成功，也不保证任意未来核心依赖变化都能自动迁移。
- 旧版完整整合包 ZIP 和局域网副本本次未重新打包或同步；GitHub 发布的是启动器补丁。

测试整理｜YuMir
