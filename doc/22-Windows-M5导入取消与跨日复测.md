# Windows M5 导入取消与跨日复测

日期：2026-10-01。基线 `e86fbbd`，应用开发预览版本为 `0.1.0-dev.12+12`。本轮继续处理 M5 的导入生命周期和性能证据，SDK、依赖缓存、测试临时目录、应用数据和预览包均继续使用 D 盘，没有升级 SDK 或依赖。

## 1. 导入取消与后台清理

扫描等待下一条文件系统事件时，原 `LibraryService.importPaths` 的 `await for` 不会因取消标记立即醒来，页面会继续保持忙碌。元数据读取虽然已经等待取消信号，但原 worker 回收只发送 `Isolate.kill`，没有确认退出；封面写出临时文件后若被终止，其内部 `finally` 不能保证执行。

扫描现使用 `StreamIterator` 和每轮单一取消监听，取消可唤醒 `moveNext` 及入库前 `file.exists` 的等待；即使异步生成器的 `cancel()` 仍在等待旧 IO，也不阻塞页面收尾。已完成歌曲保留，迟到成功和异常继续由原操作消费，不能继续入库或覆盖新一轮状态。未取消的扫描/文件检查错误仍正常计数，不作为迟到错误忽略。

每个元数据 worker 独立持有响应端口、退出端口和缓存下的 `.import-*` 暂存目录。取消、逐文件超时或关闭会停止 worker，父 isolate 在收到 `onExit` 后才清理其专属目录中的已知暂存文件。关闭最多等待 500 ms；若同步原生操作尚未返回，先解除调用方等待、保留退出监听，确认退出后再清理。启动中关闭也会阻止后续处理，若 `Isolate.spawn` 句柄迟到则补发 kill。正常封面通过重命名提交至缓存，不删除源音频、已有封面、其他会话文件或未知临时文件。

清理不遍历共享缓存，不递归删除，不跟随目录链接；锁定或不可访问的文件保留，尚未实现进程崩溃后的历史暂存清扫。有界返回不代表底层 IO 已停止。测试用隔离 worker 中的同步等待模拟延迟退出，不将其当作真实慢磁盘故障，也不声称可以强制取消 Windows 的文件系统调用。

## 2. 同一 Profile 二进制跨日复测

使用 [滚动性能复核](./17-Windows-M5滚动性能复核.md) 留存的完整 Profile 目录 `D:\dev\tmp\hanmusic-m5-row-ab\baseline`，16 份文件的大小和 SHA-256 与原清单一致。`data/app.so` SHA-256 仍为 `f7bb4dcc92aa656dd7ffc15e9d3c6084571d45e4665892d2729d55df0ebe50f2`，没有重新编译。本轮代码修改不在这份程序中。

两轮通过系统 PowerShell 5.1 执行 `tool/run_windows_performance_probe.ps1`，使用不同 `RunName` 串行采集；测量期间暂停 Flutter 测试、构建和 CPU collector，没有修改电源、显示或进程优先级。原始 JSON、CSV、session 和标准输出/错误保存于 `D:\dev\setup\verification\m5-performance-repeat-20261001`；旧固定输出先归档，没有覆盖历史证据。两轮退出码均为 0、未强制终止，CSV 重算与 JSON 一致，`validCapture=true`。

| 轮次（北京时间） | UI p95 (ms) | raster p95 (ms) | 帧数 / 实际秒数 | 采样 FPS | 超过 60 Hz 预算 | 峰值采样 RSS (MiB) | CPU 前 → 后 (%) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 10-01 09:46，r1 | 89.910 | 7.288 | 467 / 30.157744 | 15.49 | 99.79% | 148.27 | 27 → 23 |
| 10-01 09:47，r2 | 65.654 | 6.936 | 514 / 30.061825 | 17.10 | 100.00% | 148.67 | 24 → 20 |

仍为真实 PlayerPage、10000 条固定合成索引、无封面，5 秒预热后连续滚动约 30 秒。两轮逻辑窗口均为 1265.333×682.667、DPR 1.5、165 Hz、文字倍率 1.0；最大 extent 779620.333 logical px、速度 77962.033 logical px/s、三次方向改变，无测量期 metrics 变化、生命周期事件或框架错误。实际距离分别为 2345814.590、2337681.512 logical px，离散采样和测量首尾时刻存在差异。

本机 CIM 记录 Windows 11 Pro 10.0.26200、i7-13620H、16 逻辑处理器、可见内存约 15.73 GiB，测量前空闲约 2.80 GiB，当前电源方案为均衡模式。GPU 枚举同时包含 Intel UHD、RTX 4050 Laptop 和 GameViewer Virtual Display Adapter；枚举不证明本次实际渲染设备或远程会话状态。Dart 的历史探针仍返回 `Windows 10 Pro` 名称及同一 Build 26200，保留原始字段，不据此宣称切换了 OS。机器快照位于 `D:\dev\setup\verification\m5-import-lifecycle\environment.json`。CPU 为启动前/退出后的系统快照，不是全程负载、温度、功耗或本应用 CPU 占用。

测量后只读补录 D 盘为 `UMIS RPEYJ1T24MKN2QWY` NVMe、NTFS，分区 699697987584 字节，记录时剩余 63173861376 字节，见 `storage.json`。本探针仅生成内存索引，不读真实音频和封面，磁盘型号不构成此次 UI 波动的归因证据。

这份相同二进制此前 UI p95 为 26.196–26.444 ms，[之后的对照](./18-Windows-M5队列焦点与样式实验.md)为 13.978 ms，本次又为 65.654–89.910 ms。显示与工作负载主要参数一致，但系统活动等变量未完全控制，尚不能归因于内存、电源、温度、远程显示或任何代码变化。本次两轮 **UI 未达到 16.7 ms 目标**；有效采集不等于性能通过。保留原目标和历史失败，后续需在稳定、可记录的机器条件下定位波动，再进行同场次交错 A/B。

## 3. 验证与交付边界

本轮导入验证证据保存在 `D:\dev\setup\verification\m5-import-lifecycle`。

- 扫描/入库前文件检查取消：旧实现 5 项超时失败、2 项正常错误对照通过；修复后 7 项全部通过，完整 controller 测试文件 17 项通过。包含不释放旧扫描 gate 就解除 busy、保留已完成歌曲、重复取消、立即再导入，以及迟到成功/失败不污染新状态。见 `scan-before.txt`、`scan-after.txt`、`controller-regression.txt`。
- 真实 worker：新测试使用固定带封面 MP3、生产解析 isolate 和真实暂存写入，仅在写入后/重命名前加测试 gate。旧代码取消和逐文件超时两项均复现“已退出但暂存文件仍存在”，见 `worker-red.txt`。最终新增 5 项与原曲库 9 项共 **14 项通过**，见 `worker-green-final-02.txt`。覆盖取消、超时换 worker、活动读取关闭、启动期间关闭和同步阻塞后的延迟清理；旧 worker 尚未退出时，新 worker 可读 WAV，旧 worker 迟到退出后新 worker 仍可继续读取。其他文件与源音频逐次核对不变，不使用 injected metadata reader 代替该链路。
- 代码定点审查覆盖启动中关闭、迟到 isolate 句柄、独立退出与响应端口、单次取消监听、迟到错误消费及新旧导入归属。启动测试覆盖准备目录期间的关闭，未精确强制命中 `Isolate.spawn` 等待窗口；该窄分支保留代码审查结论，不伪报专门执行证据。

最终全量 `flutter test --no-pub --reporter expanded` **340 项通过**（基线 328 项，本轮新增 12 项），`dart analyze lib test tool` 无问题，81 份 Dart 文件格式检查无变化。日志为 `tests-final.txt`、`analyze-final.txt`、`format-final.txt`。4 份更新文档的 56 个本地链接有效，Git 差异检查通过。本轮未修改音频后端和运行库检查器，不重复把历史原生音频或运行库专项测试写成本轮新证据。

从干净提交 `4480ad8a84a4ac0fda4f6c87b6532d9b1782979d` 强制重建正常 `lib/main.dart` 入口（345.5 秒），生成 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.12-M5.zip`。大小 **20,496,564 字节**，SHA-256 为 `4ca066a1039ff9e5e743468f86fb1d54b0a11e7ff3ae72b759b2bbb2a1c4e06d`，共 **35 个文件**。清单记录 `version=0.1.0-dev.12+12`、`gitDirty=false`、`entryPoint=lib/main.dart`、`publicReleaseReady=false`；`data/app.so` SHA-256 为 `c1bdaa6a7159b9087a9d8825ca15743bb55568c7ff2afd4d4145dc490b3f0979`。本次构建运行库下限仍为 14.37.32822.0。

系统 PowerShell **5.1.26100.9444** 下，中文/空格解压路径的完整包 **6 项验收通过**：ZIP 哈希、所有清单文件/路径与无 UserData、运行库声明与实际 DLL 检查、启动器八秒响应、运行时数据目录锁冲突、停止后的锁释放。本机 System32 三份 x64 VC++ DLL 均为 14.51.36247.0。应用及辅助进程按本次 PID、EXE 路径和启动时间核对后精确停止，锁首次重试即取得（85 ms）；此强制停止不替代正常关窗和退出保存验收。

证据为 `package-dev12.txt`、`verify-dev12.txt`、`package-summary.json`、`package-verification-dev12.json`，原始报告位于 `D:\dev\tmp\hanmusic-m5-dev12-package-verification\验收 包 20261001-100720-544-f971c939\verification.json`。构建后仅补文档，不因文档提交重建相同源码二进制；未创建正式 Release。

真实系统文件对话框、原生关窗/最小化、系统 DPI、休眠、设备变化、物理出声、干净机器和发行授权门槛继续保留。

本次只读检查发现 Hyper-V 枚举需要当前进程没有的权限，Windows Sandbox 命令不可用；没有尝试提权、安装组件或改变系统配置，因此没有新增干净虚拟机验收。M5 仍进行中，M6 未开始。
