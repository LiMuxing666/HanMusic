# Windows M5 干净机验收交接（rc.2）

状态：**待执行**。截至 2026-10-03，尚未在没有 Flutter、Visual Studio、JDK 的 Windows x64 环境运行 rc.2；下列字段是交接记录模板，不是通过记录。rc.2 开发机完整包检查 6/6 通过，结果已记入[总计划 A4](./43-HanMusic后续开发总计划.md)，不能替代干净机播放与正常退出验收。

## 交接包

- 完整 ZIP：`HanMusic-Windows-x64-0.1.0-rc.2-M5.zip`，开发机路径为 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-rc.2-M5.zip`。
- 版本：`0.1.0-rc.2+28`，源码提交 `7652210e1a714f50067a9702bf7d440e159b97a5`（干净工作区）。
- 预期 SHA-256：`a1006183c418d200ec5b1f4d7a9856d9a8f4dc0d72aac9f3bf4b571028e26f18`。在宿主机先运行 `Get-FileHash -Algorithm SHA256 -LiteralPath '<ZIP 绝对路径>'`；不一致则停止验收。
- 保留 ZIP 内完整目录、`BUILD-MANIFEST.json`、`DISTRIBUTION-AUDIT.md` 和 `licenses/`，不要只复制 EXE。此包为开发预览，`publicReleaseReady=false`。

## 目标机最小执行步骤

1. 记录 Windows 版本、x64 架构、音频设备及机器是否安装 Flutter、Visual Studio、JDK；使用完整解压目录与独立可写数据目录。测试音频使用已知可播放且有权使用的文件，记录文件类型。
2. 在解压后的包根目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Check-Runtime.ps1 -AsJson`，保存输出。若缺少 VC++ 运行库，只使用包内 `DISTRIBUTION-AUDIT.md` 指向的 Microsoft 官方 x64 安装程序，并记录安装版本与前后检查结果；不要复制来路不明的单个 DLL。
3. 普通可写解压目录双击 `Start-HanMusic.cmd`，数据写到包旁 `UserData`；沙盒只读包按后文指定独立数据目录启动。导入一首测试音频并在实际扬声器或耳机上听到声音；记录是否出现报错或额外安装要求。
4. 用可用的匿名 JSON HTTP(S) 测试源完成一次在线搜索和播放。记录源地址或可复现描述、响应与声音结果；若没有可用源，记为“未执行”，不要记为通过。
5. 播放时设一个短定时，观察到期后暂停；正常点击窗口关闭，确认进程退出。重新从启动器打开，确认曲库、队列和进度恢复且不自动播放。

## Windows 沙盒准备

本机配置为 [tool/HanMusic-CleanRoom.wsb](../tool/HanMusic-CleanRoom.wsb)：只读映射 rc.2 完整目录和测试音频，结果目录 `D:\dev\tmp\hanmusic-cleanroom-rc2` 可写映射到 `C:\HanMusicResults`。网络开启；`AudioInput` 关闭的是麦克风输入，实际音频输出仍须在沙盒内听音验收。路径配置按 [Microsoft 官方 .wsb 文档](https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-configure-using-wsb-file)编写，所有宿主映射目录须已存在。

2026-10-03 准备检查：本机 `C:\Windows\System32\WindowsSandbox.exe` 不存在，沙盒尚未运行。rc.2 的 3 个映射目录均已存在，2 个只读、1 个可写配置检查通过；准备检查不能记为干净机通过。启用“Windows 沙盒”需要管理员操作及可能的重启，须在合适的时间安排。

启用沙盒后双击 `.wsb`，先在沙盒 PowerShell 保存 `C:\HanMusicPackage\Check-Runtime.ps1 -AsJson` 的原始输出到 `C:\HanMusicResults`，记录系统是否自带 VC++ 运行库；缺少时安装官方 x64 运行库后复检。缺库负向项只能按实际结果填写，不能预先假定。

包目录只读，因此不要双击默认将 `UserData` 写到包旁的启动器。沙盒内使用：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\HanMusicPackage\Start-HanMusic.ps1 -DataDirectory C:\HanMusicResults\UserData
```

导入 `C:\HanMusicAudio\tagged.wav` 或其他已知音频；在线源使用宿主机 fixture server 的可访问 IP，不能使用沙盒自己的 `localhost`。网络访问失败须记录，不能关闭网络测试项后判为全部通过。

## 执行记录（由目标机测试者填写）

| 字段 | 记录 |
| --- | --- |
| 日期、测试者、机器/虚拟机 | 待填写 |
| Windows 版本/build、x64、音频设备 | 待填写 |
| Flutter/Visual Studio/JDK 是否存在 | 待填写；目标环境应均未安装 |
| ZIP 实际路径、SHA-256 比对 | 待填写；当前未执行 |
| 解压路径、运行库初检/安装与复检 | 待填写；当前未执行 |
| 启动和独立 `UserData` | 待填写；当前未执行 |
| 本地文件类型、实际出声 | 待填写；当前未执行 |
| 网络测试源、搜索与实际出声 | 待填写；当前未执行 |
| 定时暂停、正常退出、重新打开恢复 | 待填写；当前未执行 |
| 额外运行条件、错误原文与复现步骤 | 待填写 |
| 结论（通过/失败/未执行） | **未执行** |

其他原生文件选择、系统缩放、真实休眠与设备切换按 [v0.1 人工验收记录](./v0.1人工验收记录.md)集中记录。项目授权、原生对应源码和依赖通知也仍未闭合，详见 [分发检查](./11-Windows依赖与分发检查.md)。填写此模板本身不能关闭 M5 或将 rc.2 标为正式发行版。
