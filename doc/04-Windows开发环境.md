# Windows 开发环境

本文记录 HanMusic 在当前电脑上的 Windows 开发环境，检查日期为 **2026-09-29**。路径是本机约定，其他电脑可按实际位置调整。

当前目标为 Windows 桌面版。Windows 构建需要 Flutter、Git、Visual Studio C++ 工具链和 Windows SDK；无需为此安装 Android Studio、Android SDK、JDK 或独立 Gradle。

## 1. 配置与验证状态

| 项目 | 本机配置 | 当前状态 |
| --- | --- | --- |
| 项目原目录 | `D:\project\音乐播放器` | 保留原位 |
| 开发目录入口 | `D:\project\HanMusic` | Junction 指向项目原目录；所有开发命令和编辑器使用此英文入口 |
| Flutter SDK | `D:\dev\flutter`，Flutter 3.41.9 stable / Dart 3.11.5 | 官方 ZIP 的 SHA256 已验证，已安装，版本命令运行通过 |
| Visual Studio | Community 2022 17.7.6，已有安装位于 C 盘 | 复用，不迁移已有工具；Flutter 检测通过 |
| MSVC | 14.37.32822 | 已发现 |
| CMake | 3.26.4 | 已发现 |
| Windows SDK | 10.0.22621.0 | 已发现 |
| VS Code | `D:\Microsoft VS Code` | 已有安装，已准备本项目专用启动器 |
| VS Code Flutter / Dart 插件 | `D:\dev\vscode\extensions`，均为 3.142.0 | 已安装，扩展列表已验证 |
| Windows 开发者模式 | 用户已开启 | 注册表值为 1，真实 SymbolicLink 创建成功，原生音频插件 Release 构建通过 |
| `flutter doctor -v` | Flutter / Windows / Visual Studio / Network | 均通过；唯一 Android SDK 警告不影响 Windows 开发 |
| `flutter pub get --enforce-lockfile` | 依赖与锁文件 | M2 新增元数据、路径及摘要依赖，已更新锁文件；Pub 缓存仍配置在 D 盘 |
| `flutter analyze --no-pub lib test tool` | 应用、测试和诊断入口 | M5 最终检查无问题，22.7 秒；完整日志见阶段验证记录 |
| `flutter test --no-pub --reporter expanded` | 音乐业务测试 | M5 最终全量 231 项通过；不包含独立原生探针和万文件 benchmark |
| Windows Release 构建 | 从英文目录入口构建 | M5 正常入口 Release 构建及预览 ZIP 完整性/短时进程检查通过；输出仍为 `build\windows\x64\runner\Release`，范围见阶段记录 |
| 应用启动与系统 UI | 原生文件对话框、窗口最小化/恢复及关闭 | 历史启动检查不等于系统交互验收；这些项目仍待实机验收 |
| M2 应用数据 | `HANMUSIC_DATA_DIR=D:\dev\data\HanMusic` | 已加入本机环境脚本和 VS Code 环境配置，存储曲库/队列状态与封面缓存 |

Flutter 3.41.9 与仓库 `.metadata` 中的 revision `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` 一致，内置 Dart 3.11.5 满足项目的 `^3.11.5` 要求。

曲库阶段的功能、测试数量、原生探针和性能结果见 [Windows M2 验证记录](./07-Windows-M2验证记录.md)。M2 核心实现完成，系统 UI 待验收；原生音频测试与 Flutter 渲染预览不能替代文件对话框和窗口操作。

M3 在同一环境继续实现完整睡眠定时和 Windows 恢复通知，没有安装新的 SDK 或新增第三方依赖。最新测试/构建结果及真实休眠验收缺口见 [Windows M3 验证记录](./08-Windows-M3验证记录.md)。本机 `HANMUSIC_DATA_DIR`、缓存和 `idea.properties` 的 D 盘配置保持不变。

Windows 插件构建会使用符号链接。用户开启开发者模式后，已复核 `AllowDevelopmentWithoutDevLicense=1`，并成功创建 `D:\dev\tmp\hanmusic-native-plugin-symlink-check`（LinkType 为 SymbolicLink，目标为 D 盘 Pub 缓存）。随后完成了带原生音频插件的 Windows Release 构建，M0 环境收尾完成。

首次 Windows Release 构建在读取 `app.dill` 时因中文路径乱码失败。已建立 `D:\project\HanMusic` 到 `D:\project\音乐播放器` 的 Junction 目录入口，未复制或移动项目。后续开发统一从英文入口进行；已确认重新生成的 CMake `PROJECT_DIR` 为英文路径，Release 构建通过。Junction 与插件所需的符号链接不同，建立目录入口不代表开发者模式已开启。

## 2. D 盘存储约定

以下为本机的环境与目录配置，启动脚本会为开发会话统一加载所需变量；Flutter 的 `bin` 目录已加入用户 `PATH`。已有终端和编辑器可能仍保留旧环境，可重新打开或直接使用下一节的启动脚本。

| 环境变量 / 数据 | 值 / 路径 | 作用 |
| --- | --- | --- |
| `FLUTTER_ROOT` | `D:\dev\flutter` | Flutter SDK；SDK 自身缓存位于其 `bin\cache` |
| `PUB_CACHE` | `D:\dev\cache\pub` | Dart / Flutter 下载的依赖包 |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn` | 与仓库现有锁文件一致的依赖源 |
| `GRADLE_USER_HOME` | `D:\dev\.gradle` | Gradle 全局缓存、Wrapper 下载和日志等 |
| `STUDIO_PROPERTIES` | `D:\idea\idea.properties` | Android Studio 自定义属性文件，当前仅预配置 |
| `HANMUSIC_DATA_DIR` | `D:\dev\data\HanMusic` | HanMusic 普通状态 JSON、有效备份及 `artwork` 封面缓存 |
| 专用 VS Code 数据 | `D:\dev\vscode\data` | 此启动方式使用的编辑器用户数据 |
| 专用 VS Code 扩展 | `D:\dev\vscode\extensions` | 此启动方式使用的扩展安装目录 |
| 会话 `TEMP` / `TMP` | `D:\dev\tmp` | 下述启动脚本及其子进程的临时目录 |

`TEMP` / `TMP` 仅由启动脚本设置，不改变其他程序的全局临时目录。项目生成的 `.dart_tool`、`build` 等位于项目自身目录，也在 D 盘。`GRADLE_USER_HOME` 不改变项目内 `.gradle` 的位置；本项目目录在 D 盘，因此项目内缓存仍在 D 盘。

`PUB_HOSTED_URL` 已设置为用户环境变量，也已加入环境脚本及项目 VS Code 的 `dart.env` / `terminal.integrated.env.windows`。`pubspec.lock` 使用该源；功能开发新增依赖时更新并提交锁文件。

`HANMUSIC_DATA_DIR` 已加入本机 `Enter-HanMusic.ps1`、VS Code 启动环境及项目的 VS Code 环境配置。它是本机部署约定，程序只接受该变量中的绝对路径；未配置或不是绝对路径时，使用 `path_provider` 提供的系统应用支持目录。直接从其他会话启动 EXE 时应确认其继承了所需变量，避免将不同数据目录误认为曲库丢失。

M2 使用 `FileAppStateStore` 保存 `state.json`、`state.backup.json` 和写入中的 `state.next.json`，不再依赖 `get_storage`。遇到较新 schema 或主备文件均损坏时保留原文件并提示只读保护；检查或迁移数据前先退出应用、保留备份，不用清空目录作为常规修复。源音频仍引用用户原文件，移除索引不会删除源文件。

### idea.properties

`D:\idea\idea.properties` 逐字复制自用户提供的附件，包含以下四个目录配置：

```properties
idea.config.path=D:/idea/setting/AsSetting/config
idea.system.path=D:/idea/setting/AsSetting/system
idea.plugins.path=D:/idea/setting/AsSetting/plugins
idea.log.path=D:/idea/setting/AsSetting/logs
```

当前未安装 Android Studio 或 IntelliJ IDEA，因此尚未通过 IDE 启动验证这些配置。Android Studio 使用 `STUDIO_PROPERTIES` 加载外部属性文件；IntelliJ IDEA 对应变量为 `IDEA_PROPERTIES`，本机未设置后者。以后安装其他 IDE 时应分别配置其数据目录，避免不同产品共用配置和缓存。属性文件中的 Windows 路径使用正斜杠，各属性指向不同目录。

## 3. 启动开发环境

在 PowerShell 中加载环境脚本，再进入英文目录入口；不要从中文原路径运行构建：

```powershell
. 'D:\dev\setup\Enter-HanMusic.ps1'
Set-Location -LiteralPath 'D:\project\HanMusic'
```

通过专用启动器打开 VS Code：

```powershell
& 'D:\dev\setup\Open-HanMusic-VSCode.cmd'
```

`.cmd` 启动器调用同目录的 `Open-HanMusic-VSCode.ps1`，由 PowerShell 调用现有 `D:\Microsoft VS Code\bin\code.cmd`，并传入 `--user-data-dir D:\dev\vscode\data` 和 `--extensions-dir D:\dev\vscode\extensions`，打开 `D:\project\HanMusic`。通过此方式启动可避免批处理中的中文路径编码问题，编辑器及其子进程也可继承 D 盘缓存和临时目录设置。

项目 `.vscode/settings.json` 保存机器专用配置，已通过 `.git/info/exclude` 在本机排除；`.vscode/extensions.json` 可共享给团队。其他电脑应使用各自的 SDK 路径。

## 4. 安装校验与开发命令

SDK 官方下载地址：

- [Flutter 3.41.9 Windows ZIP](https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.41.9-stable.zip)
- [Windows 发布清单](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json)

ZIP 的官方 SHA256：

```text
03c3235aa9e4b6fffdbac2176f803731cf5a5c998a3a5e57f840b4b202afa4f6
```

本机已使用 SHA256 验证下载文件并完成安装。其他电脑下载后应先用 `Get-FileHash -Algorithm SHA256 -LiteralPath '<下载的 ZIP 路径>'` 核对，再解压到约定位置。以下命令须在加载环境脚本并进入 `D:\project\HanMusic` 后运行：

```powershell
flutter --version
dart --version
flutter doctor -v
flutter devices
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter build windows --release
```

开发调试使用：

```powershell
flutter run -d windows
```

一键验证脚本位于 `D:\dev\setup\Verify-HanMusic.ps1`，使用英文项目入口，验证日志保存在 `D:\dev\setup\verification`：

```powershell
& 'D:\dev\setup\Verify-HanMusic.ps1'
```

构建产物位于 `D:\project\HanMusic\build\windows\x64\runner\Release`。运行或分发时需保留整个目录中的 DLL 和 `data`，不能只拷贝 EXE。当前已实现 M1–M4 核心；最新网络能力与验收边界见 [M4 验证记录](./10-Windows-M4验证记录.md)，后端历史验证见 [M1 验证记录](./06-Windows-M1验证记录.md)。使用 `-t tool/...` 构建诊断入口会覆盖同一个输出目录，交付前必须重新构建默认 `lib/main.dart`。

M4 网络源配置和备份位于 `D:\dev\data\HanMusic\online`；队列仅保存在线歌曲稳定 ID，临时流地址不写入状态文件。诊断服务与探针数据位于 `D:\dev\tmp\hanmusic-m4-probe`，验收记录归档至 `D:\dev\setup\verification\m4`。M4 无新增 SDK 或第三方依赖，Gradle、Pub、IDE 配置仍沿用上述 D 盘设置。

M5 继续沿用这些 SDK/缓存/IDE 目录，没有为验证迁移到 C 盘。万文件、Profile、音频和打包保护证据归档于 `D:\dev\setup\verification\m5`；本机硬件为 i7-13620H、16 逻辑处理器、约 15.73 GiB 可见内存、UMIS NVMe，系统为 Windows 11 Build 26200。测试模式、结果与未达标项见 [M5 阶段验证记录](./13-Windows-M5阶段验证记录.md)，不能据此认定干净 Windows 机器已通过验收。

`tool/package_windows_preview.ps1` 默认将开发预览写入 `D:\dev\releases\HanMusic`，重新构建正常入口并保留完整 Release、NOTICE、许可材料和哈希清单；不要直接打包曾由探针覆盖的 EXE。包内启动器默认把数据放在与 EXE 同目录的 `UserData` 子目录，与开发会话的 `D:\dev\data\HanMusic` 分开；保持 D 盘数据时应将预览解压到 D 盘或按 [预览运行说明](./12-Windows预览运行与验收.md) 指定绝对目录。

当前 Windows JNI DLL 由传递依赖生成，应按完整 Release 保留，不能仅凭该文件推导用户必须安装 JRE；本轮预览不捆绑 JRE 或 VC++ 运行库。VC++ 运行条件、原生许可证和项目自身授权缺口见 [分发检查](./11-Windows依赖与分发检查.md)。M5 原生音频两阶段与全量测试已完成；正常入口预览 ZIP 已通过本机哈希、完整清单及系统 PowerShell 启动器的短时进程检查，详见阶段记录第 8 节。强制结束测试进程不算正常关窗，系统交互、干净机与公开发行条件仍待完成。

模板基线验证摘要见 `D:\dev\setup\verification\result.json`，启动检查见 `launch.json`，成功构建日志见 `build-windows-ascii-path.txt`。此前中文路径失败的日志保留为 `build-windows.txt`。这些历史记录不替代当前音乐业务验证。

M1 合成音频测试工具 `imageio-ffmpeg 0.6.0` 位于 `D:\dev\tools\audio-test`，pip 缓存位于 `D:\dev\cache\pip`，测试音频及结果位于 `D:\dev\tmp\hanmusic-audio-probe`。该工具只生成测试样本，不属于应用运行依赖，不随程序发布。

验收应确认 `flutter doctor -v` 的 Windows 和 Visual Studio 项通过，`flutter devices` 中存在 Windows 设备，并成功执行分析、测试和实际 Windows 构建。仅列出已安装组件不等于构建成功。未配置 Android 工具链的提示应按 Windows 开发范围判断，不必为消除无关提示安装整套 Android 环境。

## 5. 官方参考

- [Flutter Windows 环境配置](https://docs.flutter.dev/platform-integration/windows/setup)：Visual Studio 的 `Desktop development with C++` 工作负载及验证命令。
- [Flutter 手动安装](https://docs.flutter.dev/install/manual)：SDK 存放位置与 `PATH`。
- [Flutter 3.41.9 Visual Studio 检测源码](https://github.com/flutter/flutter/blob/3.41.9/packages/flutter_tools/lib/src/windows/visual_studio.dart)：工作负载、MSVC 和 CMake 检测要求。
- [Dart pub 环境变量](https://dart.dev/tools/pub/environment-variables)：`PUB_CACHE`。
- [在中国网络环境下使用 Flutter](https://docs.flutter.dev/community/china)：本项目锁文件所用的 CFUG 依赖镜像。
- [Gradle 目录与缓存](https://docs.gradle.org/current/userguide/directory_layout.html)：`GRADLE_USER_HOME` 与项目内缓存。
- [Android Studio 配置](https://developer.android.com/studio/intro/studio-config)：`STUDIO_PROPERTIES` 和自定义属性文件。
- [IntelliJ IDEA 高级配置](https://www.jetbrains.com/help/idea/tuning-the-ide.html)：`IDEA_PROPERTIES`。
- [JetBrains IDE 数据目录](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html)：配置、缓存、插件和日志目录。
