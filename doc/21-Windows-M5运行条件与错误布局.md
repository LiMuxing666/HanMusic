# Windows M5 运行条件与错误布局

日期：2026-09-30。基线 `e141aac`，本轮开发预览为 `0.1.0-dev.11+11`。原始证据保留在 `D:\dev\setup\verification\m5-portable-runtime`，SDK、依赖缓存、临时文件、数据和预览包继续放在 D 盘，没有升级 Flutter/Dart 或应用依赖。

## 1. 运行库前置条件

此前预览包完整复制了 Flutter Release，但既未随包部署 VC++ 运行库，也未在创建数据目录和启动 EXE 前检查；缺少运行库的电脑会交给 Windows 加载器报错。开发机的运行成功会掩盖这一缺口。

只读核对 dev.10 EXE 与音频插件，两者均普通导入 `MSVCP140.dll`、`VCRUNTIME140.dll`、`VCRUNTIME140_1.dll`。当前构建 MSVC 为 **14.37.32822**，本机 VS 的 REDIST DLL 和安装程序为 **14.36.32532.0**，低于本构建工具链；System32 中三份 DLL 为 **14.51.36247.0**。没有从旧 REDIST 或 System32 收集 DLL，也没有运行安装程序。证据为 `runtime-baseline.json`、`runtime-baseline-dumpbin.txt`，包含实际文件路径、版本、哈希及采集时间。

部署选择为中央安装：使用 Microsoft 官方 x64 v14 运行库安装程序；本轮增加包内只读检查，不把它描述为已经自动安装或解决所有干净机条件。Microsoft 要求目标架构匹配、运行库不早于编译工具，并推荐中央安装以便独立维护。应用目录部署也是一种路径，但现有旧版文件不作为此次包的默认来源。[版本与下载条件](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)、[Microsoft 部署说明](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files)、[Flutter ZIP 所需文件](https://docs.flutter.dev/platform-integration/windows/building#building-your-own-zip-file-for-windows)

打包脚本在本次正常入口构建后，从 CMake 缓存里的 x64 MSVC linker 路径提取最低版本，生成 `RUNTIME-REQUIREMENTS.json`，并将相同对象写入 `BUILD-MANIFEST.json`。工具链无法识别时拒绝打包，不能沿用旧构建要求或依赖 shell PATH。

`Start-HanMusic.cmd` 调用的启动脚本先运行 `Check-Runtime.ps1`，通过后才创建/检测 UserData 并启动应用。检查器读取实际 DLL 的 PE 架构与数字文件版本，优先处理 EXE 旁文件；本地副本存在但损坏、架构错误或过旧时，不用系统目录中的正常副本掩盖它。缺失或不满足条件会提示官方安装链接；单独加 `-AsJson` 可获得机器可读结果。检查不加载 DLL、不安装或下载软件，不创建应用数据，不修改 PATH 或系统设置。

要求只涵盖当前声明的三份 VC++ DLL。文件条件通过不证明 Windows 加载器最终成功、不涵盖所有动态加载依赖或运行库符号兼容性，也不代替干净 Windows 上的启动、音频和保存验收。包验证会核对声明与清单一致、保存实际前置检查结果，再执行原有启动和目录锁检查。

JNI 另行核对：dev.10 的 `dartjni.dll` 普通导入 `jvm.dll`，Delay Import Directory 为 0；不能把其构建源码中的 `/DELAYLOAD` 当作产物事实。当前 Windows 主路径没有调用 JNI，生成的 Windows 插件注册分支也未注册 JNI；`DynamicLibrary.open` 的惰性和 JVM 普通导入是两回事。保留正常构建产物，不捆绑或要求安装 Java，实际无 Java 环境的完整功能验证仍保留。

## 2. 紧凑窗口组合错误

使用真实 PlayerPage，在 800×600、200% 字号下触发播放加载失败并同时触发在线搜索失败，原在线页面固定堆叠控制区、提示区和结果区，导致纵向溢出；重试操作可能被固定播放条区域挤出。

本轮将在线页改为单一滚动区域：控制和提示使用 sliver，结果列表保留按需构建，空/加载状态仍填充可用空间。全局播放错误与固定播放条保留在父层，两个错误均保留，不通过降低字号或隐藏错误解决。

正式 Windows 平台回归在 800×600/200% 字号下复现 **41 px** 溢出，1280×720/100% 对照通过。修复后两场景均通过；测试滚动访问错误与重试，通过 Tab/Enter 执行重试，并确认可到达固定播放条。在线页面测试共 **12 项通过**，定点静态分析无问题。证据为 `online-combined-errors-before.txt`、`online-combined-errors-after.txt`、`online-widget-regression.txt`、`online-layout-analyze.txt`。早期本机临时夹具用于调查，不替代这份正式回归记录。

这些是 Flutter 框架中的 Windows 平台与字号组合检查，不等同于修改真实系统 DPI 或原生键鼠操作。

## 3. 最终验证与预览

全量 `flutter test --no-pub --reporter expanded` **328 项通过**，其中本轮新增 2 项组合错误回归；`dart analyze lib test tool` 无问题，79 份 Dart 文件格式检查无变化。证据为 `tests-final.txt`、`analyze-final.txt`、`format-final.txt`。

系统 PowerShell 5.1 下，**20 项运行库专项检查通过**，包括最低版本等值、缺失/过旧/x86 DLL、损坏/过旧本地副本不回退、ARM64 拒绝、32 位 shell 的 Sysnative 路径、损坏/重复/非法要求，以及真实 CLI 的纯 JSON 和退出码。PE 头来自受控测试文件，数字版本和平台信息用于隔离测试时注入，没有修改 System32；不把这些夹具当作真实旧系统。证据归档为 `runtime-check-tests.json`。

另用本机真实 DLL 分别在 64 位和 32 位 Windows PowerShell 5.1 运行正式 CLI：三份 x64 文件均为 14.51.36247.0，32 位 shell 正确读取 Sysnative，两个进程退出码均为 0；未创建 UserData。记录为 `runtime-host.json`、`runtime-host-x86-powershell.json`。从实际打包脚本提取启动器，以非法运行条件配置触发失败，退出码 1、UserData 未创建，见 `launcher-guard.json` 与 `launcher-invalid-requirements.txt`。

**15 项打包保护检查通过**，新增 6 项工具链识别用例覆盖当前 x64、新版工具链/x86 host、缺失、歧义、ARM64 target 和无版本路径。原有越界/已有输出/目录链接保护及原生命令 stderr/退出码检查保留，既有包、外部标记和构建 EXE 未被拒绝的请求修改。证据为 `packaging-guards.txt`；文档 5 份、54 个本地链接有效，Git 差异检查通过。

dev.11 完整预览包将在干净代码提交后重建正常 `lib/main.dart`，包结果另行补记。

本轮没有变更音频后端，也不重复把上一轮原生音频/PCM 结果当成本轮新测试。真实系统文件对话框、最小化/正常关窗、休眠、设备变化、物理出声、真实 DPI、性能跨时段稳定性、干净机器和发行授权/原生源码材料仍按 [开发计划](./05-Windows版本开发计划.md) 保留。
