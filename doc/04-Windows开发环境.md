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
| Windows 开发者模式 | 尚未开启 | 符号链接测试提示需要管理员权限，待用户手动开启 |
| `flutter doctor -v` | Flutter / Windows / Visual Studio / Network | 均通过；唯一 Android SDK 警告不影响 Windows 开发 |
| `flutter pub get --enforce-lockfile` | 保留现有锁文件 | 通过；24 个外部依赖包均在 D 盘，未引用 C 盘包 |
| `flutter analyze` | 当前项目 | 通过 |
| `flutter test` | 当前项目现有测试 | 1 个 widget test 通过 |
| Windows Release 构建 | 从英文目录入口构建 | 通过，生成 `build\windows\x64\runner\Release\han_music.exe` |
| 应用启动冒烟检查 | 启动 Release 程序并观察 8 秒 | 进程未提前退出，随后关闭；未进行界面交互验收 |

Flutter 3.41.9 与仓库 `.metadata` 中的 revision `00b0c91f06209d9e4a41f71b7a512d6eb3b9c694` 一致，内置 Dart 3.11.5 满足项目的 `^3.11.5` 要求。

Windows 插件构建会使用符号链接。本机尝试创建符号链接时失败，提权操作返回“用户取消”，因此不再自动触发 UAC。请在 Windows 设置中搜索“开发者模式”并开启，随后重新执行环境和构建检查。

首次 Windows Release 构建在读取 `app.dill` 时因中文路径乱码失败。已建立 `D:\project\HanMusic` 到 `D:\project\音乐播放器` 的 Junction 目录入口，未复制或移动项目。后续开发统一从英文入口进行；已确认重新生成的 CMake `PROJECT_DIR` 为英文路径，Release 构建通过。Junction 与插件所需的符号链接不同，建立目录入口不代表开发者模式已开启。

## 2. D 盘存储约定

以下变量已写入当前用户的环境变量；Flutter 的 `bin` 目录也已加入用户 `PATH`。已有终端和编辑器可能仍保留旧环境，重新打开即可；也可以直接使用下一节的启动脚本。

| 环境变量 / 数据 | 值 / 路径 | 作用 |
| --- | --- | --- |
| `FLUTTER_ROOT` | `D:\dev\flutter` | Flutter SDK；SDK 自身缓存位于其 `bin\cache` |
| `PUB_CACHE` | `D:\dev\cache\pub` | Dart / Flutter 下载的依赖包 |
| `PUB_HOSTED_URL` | `https://pub.flutter-io.cn` | 与仓库现有锁文件一致的依赖源 |
| `GRADLE_USER_HOME` | `D:\dev\.gradle` | Gradle 全局缓存、Wrapper 下载和日志等 |
| `STUDIO_PROPERTIES` | `D:\idea\idea.properties` | Android Studio 自定义属性文件，当前仅预配置 |
| 专用 VS Code 数据 | `D:\dev\vscode\data` | 此启动方式使用的编辑器用户数据 |
| 专用 VS Code 扩展 | `D:\dev\vscode\extensions` | 此启动方式使用的扩展安装目录 |
| 会话 `TEMP` / `TMP` | `D:\dev\tmp` | 下述启动脚本及其子进程的临时目录 |

`TEMP` / `TMP` 仅由启动脚本设置，不改变其他程序的全局临时目录。项目生成的 `.dart_tool`、`build` 等位于项目自身目录，也在 D 盘。`GRADLE_USER_HOME` 不改变项目内 `.gradle` 的位置；本项目目录在 D 盘，因此项目内缓存仍在 D 盘。

`PUB_HOSTED_URL` 已设置为用户环境变量，也已加入环境脚本及项目 VS Code 的 `dart.env` / `terminal.integrated.env.windows`。原 `pubspec.lock` 使用该源，已通过 `--enforce-lockfile` 验证并保持锁文件不变。

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

本次构建产物位于 `D:\project\HanMusic\build\windows\x64\runner\Release`。运行或分发时需保留整个目录中的 DLL 和 `data`，不能只拷贝 EXE。当前程序仍是仓库原有的计数器示例，构建通过不代表音乐功能已经实现。

本次验证摘要见 `D:\dev\setup\verification\result.json`，启动检查见 `launch.json`，成功构建日志见 `build-windows-ascii-path.txt`。此前中文路径失败的日志保留为 `build-windows.txt`，便于排查。

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
