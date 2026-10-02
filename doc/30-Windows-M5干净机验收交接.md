# Windows M5 干净机验收交接（dev.16）

状态：**待执行**。截至 2026-10-02，尚未在没有 Flutter、Visual Studio、JDK 的 Windows x64 环境运行本包；下列字段是交接记录模板，不是通过记录。开发机上的 6 项包完整性、启动响应和目录锁检查见 [中文歌曲标题字体复核](./29-Windows-M5中文歌曲标题字体复核.md)，不能替代干净机播放与正常退出验收。

## 交接包

- 完整 ZIP：`HanMusic-Windows-x64-0.1.0-dev.16-M5.zip`，开发机路径为 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.16-M5.zip`。
- 预期 SHA-256：`f7886515b36639f11f5f464886a732f68f0e14a28517d116bb8457e5f658a958`。在目标机先运行 `Get-FileHash -Algorithm SHA256 -LiteralPath '<ZIP 绝对路径>'`；不一致则停止验收。
- 保留 ZIP 内完整目录、`BUILD-MANIFEST.json`、`DISTRIBUTION-AUDIT.md` 和 `licenses/`，不要只复制 EXE。此包为开发预览，`publicReleaseReady=false`。

## 目标机最小执行步骤

1. 记录 Windows 版本、x64 架构、音频设备及机器是否安装 Flutter、Visual Studio、JDK；将完整 ZIP 解压到 D 盘可写目录。测试音频也放在 D 盘，使用已知可播放且有权使用的文件，记录文件类型。
2. 在解压后的包根目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Check-Runtime.ps1 -AsJson`，保存输出。若缺少 VC++ 运行库，只使用包内 `DISTRIBUTION-AUDIT.md` 指向的 Microsoft 官方 x64 安装程序，并记录安装版本与前后检查结果；不要复制来路不明的单个 DLL。
3. 双击 `Start-HanMusic.cmd`，确认应用启动，数据写到包旁 `UserData`。导入一首测试音频并在实际扬声器或耳机上听到声音；记录是否出现报错或额外安装要求。
4. 用可用的匿名 JSON HTTP(S) 测试源完成一次在线搜索和播放。记录源地址或可复现描述、响应与声音结果；若没有可用源，记为“未执行”，不要记为通过。
5. 播放时设一个短定时，观察到期后暂停；正常点击窗口关闭，确认进程退出。重新从启动器打开，确认曲库、队列和进度恢复且不自动播放。

## 执行记录（由目标机测试者填写）

| 字段 | 记录 |
| --- | --- |
| 日期、测试者、机器/虚拟机 | 待填写 |
| Windows 版本/build、x64、音频设备 | 待填写 |
| Flutter/Visual Studio/JDK 是否存在 | 待填写；目标环境应均未安装 |
| ZIP 实际路径、SHA-256 比对 | 待填写；当前未执行 |
| 解压路径、运行库初检/安装与复检 | 待填写；当前未执行 |
| 启动和 D 盘 `UserData` | 待填写；当前未执行 |
| 本地文件类型、实际出声 | 待填写；当前未执行 |
| 网络测试源、搜索与实际出声 | 待填写；当前未执行 |
| 定时暂停、正常退出、重新打开恢复 | 待填写；当前未执行 |
| 额外运行条件、错误原文与复现步骤 | 待填写 |
| 结论（通过/失败/未执行） | **未执行** |

其他原生文件选择、系统缩放、真实休眠与设备切换仍按 [预览运行与验收](./12-Windows预览运行与验收.md) 单独记录。项目授权、原生对应源码和依赖通知也仍未闭合，详见 [分发检查](./11-Windows依赖与分发检查.md)。填写此模板本身不能关闭 M5 或将 dev.16 标为正式发行版。
