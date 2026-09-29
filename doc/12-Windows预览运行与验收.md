# HanMusic Windows 开发预览：运行与手工验收

本包为 Windows x64 **0.1.0-dev.5+5 开发预览**，不是已完成发行验收的 v0.1。包含完整 Flutter Release 目录、启动器、文件校验清单及依赖说明；没有安装器、数字签名或自动更新。

## 运行

1. 将整个 ZIP 解压到可写目录，例如 `D:\Apps\HanMusic`。不要直接从 ZIP 内运行，也不要只复制 EXE。
2. 双击 `Start-HanMusic.cmd`。启动器检查目录可写，然后使用同目录 `UserData` 保存曲库索引、队列、在线源和封面。解压到 D 盘即可使这些数据留在 D 盘。
3. 导入文件或文件夹后，在曲库中点击歌曲播放。当前支持本地曲库、队列/四种模式、睡眠定时，以及通用匿名 JSON HTTP(S) 网络源。
4. 退出前关闭应用窗口。复制或升级包时，可在应用关闭后把 `UserData` 复制到新目录，保留原备份；本次开发机上的强制结束冒烟检查不等于已验证正常关窗。

直接双击 `han_music.exe` 会沿用系统已有的 `HANMUSIC_DATA_DIR`；未配置时使用系统应用数据目录，可能位于 C 盘。需要固定 D 盘数据时请使用启动器，或运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-HanMusic.ps1 -DataDirectory 'D:\HanMusicData'
```

启动器不修改系统环境变量和执行策略。`Bypass` 仅作用于本次 PowerShell 进程。当前未实现同一数据目录的多实例锁，请一次只启动一个实例，避免同时写入同一份状态。

## 运行条件与故障排查

- 本机已验证 Windows 11 x64 Build 26200；Windows 10、ARM64 和未安装开发工具的干净系统尚未完成实测。
- 程序运行无需 Flutter/Visual Studio SDK。不要移除 Flutter DLL、`libmpv-2.dll`、音频插件、`dartjni.dll` 或 `data`。
- 本包没有捆绑 Microsoft Visual C++ 运行库；出现 `MSVCP140.dll` / `VCRUNTIME140.dll` 等缺失提示时，使用 Microsoft 官方 x64 v14 运行库安装程序。具体版本要求、官方链接和当前 JNI 分析见包内 `DISTRIBUTION-AUDIT.md`，源码仓库对应 `doc/11-Windows依赖与分发检查.md`。不因存在 JNI 文件而直接要求用户安装 JRE。
- 若被 Windows 标记为未识别的应用，先核对 ZIP SHA-256、来源和文件清单。包尚未签名；本手册不要求关闭系统安全防护。
- 只移除曲库索引，不删除源音乐文件。源文件移动或磁盘断开后，使用曲库的文件检查，再按提示处理缺失项。
- 读取到较新 schema 或损坏且无有效备份的数据时，会保留原文件并提示无法保存更改；不要直接用空文件覆盖原数据。
- 在线源目前只支持匿名 GET JSON、点分字段映射和分页，不支持商业平台登录、Token、Cookie 或自定义 Header。歌曲加载前取新地址，失效地址仅重新解析一次。
- 本机开发测试源用 `dart run tool/online_fixture_server.dart` 启动，配置见仓库 `doc/examples/online-source.local.json`；此命令属于源码开发工具，不是预览包的运行依赖。预览包用户需要自己的兼容服务。

## 包内容与校验

| 文件 | 用途 |
| --- | --- |
| `Start-HanMusic.cmd` / `.ps1` | 以相邻 `UserData` 或指定绝对目录启动 |
| `han_music.exe`、DLL、`data/` | 正常 `lib/main.dart` Release 应用；必须一起保留 |
| `BUILD-MANIFEST.json` | 版本、源码提交、是否有未提交改动、逐文件大小与 SHA-256；不把工作区未提交状态描述为干净提交 |
| `THIRD-PARTY-NOTICES.txt` | 展开的 Flutter/Dart 依赖通知；不能代替原生媒体库的独立许可 |
| `licenses/`、`DISTRIBUTION-AUDIT.md` | 已核对的额外许可材料与尚未解决的对外分发条件 |
| `DEPENDENCIES.lock` | 构建使用的 Dart 依赖版本 |
| `PREVIEW-STATUS.txt` | 开发预览与未完成门槛摘要 |
| 同 ZIP 名的 `.sha256` | 整个 ZIP 的校验值 |

文件清单不含自身及首次启动后产生的 `UserData`；ZIP 校验值覆盖整个压缩包。构建脚本每次清理经路径校验的生成目录并重建 `lib/main.dart`，不把上一次诊断入口直接压缩交付。

## 待执行的手工验收

请在可暂停当前工作的测试环境执行电源或设备测试。下面是操作步骤和预期结果，不是已通过记录；实际测试时补上日期、OS、机器、音频设备、缩放、包 SHA-256 和观察。

| 项目 | 操作 | 预期 |
| --- | --- | --- |
| 系统文件选择器 | 选择多个音频、取消，再选择中文/空格目录 | 成功入库，取消不改变曲库；不修改源文件 |
| 最小化/恢复 | 播放至少 30 秒，最小化再恢复 | 音频继续，界面与进度同步 |
| 正常关闭/重开 | 播放中关窗，确认进程退出，再启动 | 音频停止，进程释放；队列和进度恢复但不自动播放 |
| 系统缩放 | 分别设置 100%/150%/200%，重开应用，检查导航、曲库、在线源编辑、定时弹窗及固定播放条 | 关键操作可达，无遮挡和溢出；字号模拟测试不替代此项 |
| 睡眠未跨截止 | 设置 10 分钟定时，系统休眠约 1 分钟后唤醒，分别在前台/最小化运行 | 继续按原截止计时，不重设完整时长 |
| 睡眠跨截止 | 设置 1 分钟定时，休眠超过截止后唤醒，分别在前台/最小化运行 | 恢复后暂停，保留队列/进度，不自动切歌 |
| 音频设备变化 | 播放时切换默认输出设备；在独立测试设备插拔耳机 | 记录是否继续或受控报错；界面不能假称播放成功/崩溃 |
| 干净机器 | 使用未安装 Flutter/Visual Studio/JDK 的 Windows x64 系统解压；按缺失情况仅安装官方 VC 运行库 | 可启动、本地/网络播放、定时、正常退出和恢复；记录所有额外运行条件 |
| 包完整性 | 解压后核对所有清单文件；复制到中文/空格目录再启动 | 校验一致，启动器和本地数据路径正常 |

对外发行前还须解决原生依赖对应源码/完整通知、项目本身的授权决定、真实音频输出起播测量及性能门槛。此预览包不作为完成这些条件的证明。

## 开发者复现打包

使用已配置的 Windows 工具链，在英文项目入口执行：

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
.\tool\package_windows_preview.ps1 -OutputRoot 'D:\dev\releases\HanMusic'
```

脚本只清理项目内 `build/windows/x64/runner/Release`，拒绝目录越界、链接目标、仍在运行的构建目录应用和覆盖既有预览包。每次构建都写明开发预览状态；不会上传 GitHub Release 或安装系统运行库。
