# HanMusic

基于 Flutter 的音乐播放器项目，计划提供本地曲库、自定义网络源播放与睡眠定时。

当前在 `Windows_lmx` 分支推进 Windows x64 版本，已实现 M1 单曲播放原型：系统文件选择、文件名与格式展示、播放/暂停、进度拖动、音量和最小睡眠定时。曲库、队列、网络源设置与持久化将按后续里程碑实现。

导入音频后自动播放；取消文件选择保留当前歌曲。睡眠定时支持 15/30/60 分钟及自定义正整数分钟，到期暂停，取消后继续原播放状态。关闭程序后定时失效。当前标题以文件名为准，封面为占位图形。

## 开发文档

- [Windows 版本开发计划](doc/05-Windows版本开发计划.md)：阶段任务、依赖、验收标准与交付范围。
- [Windows 开发环境](doc/04-Windows开发环境.md)：SDK、D 盘缓存、VS Code 启动方式和构建命令。
- [Windows M1 验证记录](doc/06-Windows-M1验证记录.md)：音频后端组合、复现命令、异常恢复与验证边界。
- [技术架构要求](doc/01-技术架构要求.md)
- [需求文档](doc/02-需求文档.md)
- [功能说明文档](doc/03-功能说明文档.md)

Windows 本轮范围以开发计划为准。原跨平台设计保留，其他平台不作为本轮验收条件。

## Windows 开发

当前验证基线为 Flutter 3.41.9 / Dart 3.11.5，配合 Visual Studio C++ 桌面工具链。构建工程使用不含中文的路径；本机通过 `D:\project\HanMusic` 目录入口访问原项目。

配置 SDK、Pub 缓存和与锁文件一致的依赖源后，在项目目录运行：

```powershell
flutter pub get --enforce-lockfile
flutter analyze --no-pub lib test tool
flutter test --no-pub
flutter build windows --release --no-pub
```

Release 输出为 `build/windows/x64/runner/Release`；运行时保留整个目录，不仅复制 EXE。本机开发者模式、符号链接和原生插件构建已通过验证。其他机器需完成对应环境配置，详见环境文档。

`tool/windows_audio_probe.dart` 与 `tool/windows_app_probe.dart` 是独立诊断入口，不是正常应用入口；运行诊断后重新执行默认 Release 构建。当前交付为开发原型，尚未完成干净机器分发和 M5 发行验收。
