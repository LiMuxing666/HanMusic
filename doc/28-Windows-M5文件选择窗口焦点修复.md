# Windows M5 文件选择窗口焦点修复

日期：2026-10-02。用户在 dev.14 预览的真实 Windows 桌面测试中反馈：点击“导入音乐”后，文件选择窗口**刚出现时**闪烁、卡顿。用户尚未对修复版做视觉复测，因此不能将该现象标记为已消除。

## 定位与改动

`windows/runner/win32_window.cpp` 原先对每次 `WM_ACTIVATE` 都调用 `SetFocus(child_content_)`，包括主窗口正在失活的 `WA_INACTIVE`。系统文件窗口出现时主窗口会失活；[Microsoft 的 WM_ACTIVATE 文档](https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-activate)说明了该通知的含义，[SetFocus 文档](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setfocus)说明设置焦点也会激活目标或其父窗口。现在只在主窗口激活时把焦点交给 Flutter 子窗口，失活时不再回抢。该原始逻辑也存在于当前 Flutter Windows 模板，源码分析不能单独证明它就是唯一触发原因。

`LocalLibraryPicker` 的多文件和目录入口，以及 `LocalSongPicker` 的单文件入口，原先均采用 `WindowsOptions.lockParentWindow=false` 的默认值。锁定的 `windows_file_picker 2.0.0` 因此以空所属窗口句柄调用系统 `IFileOpenDialog.Show`；[上游变更记录](https://github.com/vicajilau/flutter_file_picker/blob/main/packages/file_picker/CHANGELOG.md)说明开启该参数后，选择框会作为模态窗口保持在 Flutter 主窗口前。三个入口现在统一传入 `WindowsOptions(lockParentWindow: true)`。插件仍在独立 Dart isolate 打开系统窗口，导入扫描逻辑未改。

模态行为意味着文件窗口打开时，先完成或取消选择，才能点击主窗口关闭。退出期间迟到选择结果的旧保护仍保留，覆盖系统退出等非主窗口点击路径。插件默认通过后台 isolate 的 `GetForegroundWindow()` 找所属窗口；快速切换应用的极端竞态仍需留意，本轮未改插件或加入私有 API。

## 验证与待确认

新增三个平台接口测试，检查多文件、目录、单文件入口均请求 Windows 模态选择框，并保留取消选择的行为。定向测试 3/3 通过。首次默认并行全量测试 370 项通过、4 项失败，失败均发生在未改动的元数据 worker 或受控 HTTP 测试，表现为超时/时序断言；这四项所在的文件串行定向复跑 40/40 通过，随后完整串行全量测试 **374/374 通过**。保留两份原始日志 `D:\dev\tmp\hanmusic-dev15-tests.txt`、`D:\dev\tmp\hanmusic-dev15-tests-serial.txt`，不把第一次失败写成全量通过。

`flutter analyze --no-pub` 无问题；`dart format --output=none --set-exit-if-changed lib test tool` 检查 82 个文件、0 个待格式化。平台接口测试只模拟 `FilePickerPlatform` 参数，不弹出真实系统窗口。Windows runner 已通过 Release 编译，但焦点分支仍需真实桌面复测；打开瞬间是否还出现闪烁、停顿，以及其他 Shell 扩展或最近目录加载开销，不能由 Flutter 单元测试证明。具体手工步骤已写入[预览运行与验收](./12-Windows预览运行与验收.md)，M5 对话框验收继续待用户反馈。

## dev.15 本地预览包

从干净提交 `fb227d7f7e69a15bf959f628a29348e7a7afaf4e` 构建正常入口 `lib/main.dart` 的 Windows Release，原生编译完成（198.1 秒）。完整包为 `D:\dev\releases\HanMusic\HanMusic-Windows-x64-0.1.0-dev.15-M5.zip`，20,986,116 字节，SHA-256 为 `76bf3bf164844004ddb10bda88c3092916fc91d6a27bfc140877cc7629a64af4`；清单覆盖 34 个内容文件，另有清单文件，`gitDirty=false`，`publicReleaseReady=false`。

用系统 Windows PowerShell 5.1 在 D 盘中文和空格目录解压，**6 项完整包检查通过**：ZIP SHA、逐文件清单与无预置 UserData、x64 运行库检查、打包启动器八秒响应、运行中数据目录锁、停止独立验收进程后锁释放。报告见 `D:\dev\setup\verification\m5-picker-dev15\验收 包 20261002-101242-482-64fc4d08\verification.json`。该检查只终止自己新启动并核对 PID、路径和启动时间的验收副本；不涉及先前用户手测的 dev.14 进程。强制停止并不能替代正常关窗保存，也没有操作原生文件选择窗口。用户仍需使用 dev.15 可见窗口复测打开瞬间的闪烁和卡顿。
