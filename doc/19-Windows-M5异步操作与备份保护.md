# Windows M5 异步操作与备份保护

日期：2026-09-30。基线提交 `93d16f1`，开发预览推进为 `0.1.0-dev.9+9`。本轮聚焦异步操作完成时的归属、网络源编辑等待状态和有效备份保护，不改变状态 schema、网络源协议或依赖版本。证据目录为 `D:\dev\setup\verification\m5-async-stability`，开发环境、缓存、测试临时目录与产物继续使用 D 盘配置。

## 1. 迟到的重播结果

歌曲 A 结束后重新播放，需要先跳转到开头。如果这次跳转尚未完成，用户已经切换并开始播放 B，A 随后返回的失败原本仍会交给当前歌曲的错误处理器；默认启用自动跳过时，B 可能被当作坏文件暂停并跳到 C。另一个对称问题是：同曲重播等待期间暂停并重新定位后，旧跳转成功返回仍可能把界面位置覆盖为零。

本轮针对 Future 完成后的处理校验播放意图与加载代际。已被切歌或暂停取代的操作不能修改当前歌曲状态或触发错误跳过；仍属于当前操作的失败继续按跳过设置处理。这项修复不声称为后端无操作标识的全局事件流补上了事件归属。

独立复核还扩充“暂停后旧重播失败”的同一测试，实际执行下一次播放。第一次修复只消化旧错误，但过早清除了曲目结束标记，重试时没有再次回到曲首；`playback-retry-before-fix.txt` 复现实际仅一次 seek(0)、预期两次的失败。最终改为在归属仍有效的 seek 成功后清除结束标记，并验证等待期间重复完成通知不会额外切歌、真正播放结束后仍正常推进。

## 2. 网络源保存时的输入

“测试并保存”在请求发出时捕获 JSON 配置与测试关键词，但此前等待期间两个字段仍可修改。测试成功后弹窗关闭，保存的是请求开始时的配置，等待期间继续输入的内容会被丢弃。

等待测试和保存期间，两个字段统一只读，保存和取消按钮维持原有忙碌状态；失败后保留内容并恢复编辑。测试使用受控异步请求覆盖等待、失败后重试和成功提交，不依赖外部网络源响应速度。

## 3. 有效备份保护

曲库状态与网络源配置都允许在主文件损坏时从有效备份恢复。此前下一次保存直接截断并重写该备份；若在部分写入后失败，主文件仍损坏、备份也不完整，重启无法自动恢复，即使新快照的临时文件仍在。

备份更新改为先在同目录写入独立的 `*.backup.next.json`，完成写入及 flush 后再替换正式备份，之后沿用原有主文件提交顺序。写入失败由现有调用方报告；待提交临时文件不作为启动时的有效快照。格式、已知有效快照和串行保存屏障保持原有约定。

核对本机 Dart 3.11.5 对应的 [Windows 文件重命名实现](https://github.com/dart-lang/sdk/blob/3.11.5/runtime/bin/file_win.cc#L660-L674)：普通文件替换使用 `MoveFileExW` 的 `MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH`，没有先单独删除普通目标文件的步骤。下面的实测范围仍以注入故障为限。

故障注入仅操作每项测试新建的 D 盘临时目录：分别在备份部分写入后、备份替换前、主文件替换前抛出异常，并检查新建 store 仍能恢复旧快照，随后原实例可以重试并保存新快照。该验证覆盖可控文件操作失败，不等于真实断电、磁盘硬件故障或任意文件系统的持久性保证。

## 4. 验证与交付

新增 13 项回归，按问题分别先复现再修复：

| 范围 | 修复前 | 修复后 |
| --- | --- | --- |
| 重播 Future 完成结果 | 3 个过期操作场景失败；2 个当前有效错误对照通过 | 播放服务文件 21 项通过，含新增 5 项 |
| 网络源编辑 | 2 项均接受等待期间的输入，导致回归失败 | 在线页面文件 10 项通过，含新增 2 项 |
| 曲库/源配置备份 | 两类 store 的部分写入故障均丢失自动恢复能力；主文件替换前失败对照通过 | 两份 store 测试共 24 项通过，含新增 6 项故障场景 |

原始证据为 `playback-before-fix.txt` / `playback-after-fix.txt`、`online-editor-before.txt` / `online-editor-after.txt` / `online-widget-regression.txt`、`store-backup-red-02.txt` / `store-backup-green.txt`。重播复核补项后的 21 项最终回归为 `playback-retry-after-fix.txt`，另有 11 项队列完成事件相关回归通过，见 `playback-retry-summary.json`。最初 `store-backup-red.txt` 为测试辅助代码的 Zone 递归错误，已修正，不算产品缺陷的复现证据；首次完成事件筛选命令存在 shell 转义错误，修正后才取得有效的 11 项结果。

最终 `flutter test --no-pub --reporter expanded` **296 项通过**（43 秒）；`dart analyze lib test tool` 无问题；`dart format --output=none --set-exit-if-changed lib test tool` 检查 79 个文件、0 变化。证据分别为 `tests-final.txt`、`analyze-final.txt`、`format-final.txt`。这轮没有性能测量，不把测试耗时当作曲库性能指标。

从干净提交 `26cb05f0e9d5d12501989d4e55cf2e9a63f93164` 重建正常入口 `lib/main.dart` 的 Release（96.8 秒），生成 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.9-M5.zip`。ZIP 大小 **20,475,336 字节**，SHA-256 为 `7f53ceabf5c397cfa7830d7c74e26aff503ed36db08fda280881bbe64135376e`；32 个内容文件加清单共 33 个，`version=0.1.0-dev.9+9`、`gitDirty=false`、`channel=development-preview`、`publicReleaseReady=false`。正常应用的 `data/app.so` SHA-256 为 `e05d93dd202b241756decfe864f485a171fdbbe254d08c011868d48ccc29ec50`。

系统 PowerShell **5.1.26100.9444** 下，`tool/verify_windows_preview.ps1 -CheckDataDirectoryLock` 验收通过：ZIP 及全部清单文件哈希一致，包内无 UserData；独立中文/空格目录内由 `Start-HanMusic.cmd` 启动，持续八秒响应，启动器退出码为 0，UserData 与 online 目录在 D 盘创建。运行时目录文件范围锁返回预期 Win32 错误 33；精确核对本轮 PID、EXE 路径和启动时间后终止测试进程，首次重试取得锁（44 ms），测试进程与辅助进程均已清理。

打包日志为 `package-dev9.txt`，元数据为 `package-summary.json`，验收报告归档为 `package-verification-dev9.json`。原报告保留在 `D:\dev\tmp\hanmusic-m5-dev9-package-verification\验收 包 20260930-142252-920-02d41f37\verification.json`。这是开发机上的包完整性、启动响应和目录锁检查；强制终止不等于正常关窗或持久化验收，锁冲突不等于第二实例 UI 验收。

本轮未执行原生文件/目录对话框、真实键鼠、最小化/恢复/正常关窗、真实休眠、音频设备切换或系统 DPI 操作，也未完成无开发工具的干净机器验证。性能跨时段稳定性和正式发行条件继续按 [开发计划](./05-Windows版本开发计划.md) 保留，不以自动测试或开发机启动响应代替。
