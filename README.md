# HanMusic

基于 Flutter 的音乐播放器项目，计划提供本地曲库、自定义网络源播放与睡眠定时。

当前在 `Windows_lmx` 分支推进 Windows x64 版本。开发环境和原有计数器模板的 Windows Release 构建已验证，音乐业务功能尚未实现。

## 开发文档

- [Windows 版本开发计划](doc/05-Windows版本开发计划.md)：阶段任务、依赖、验收标准与交付范围。
- [Windows 开发环境](doc/04-Windows开发环境.md)：SDK、D 盘缓存、VS Code 启动方式和构建命令。
- [技术架构要求](doc/01-技术架构要求.md)
- [需求文档](doc/02-需求文档.md)
- [功能说明文档](doc/03-功能说明文档.md)

Windows 本轮范围以开发计划为准。原跨平台设计保留，其他平台不作为本轮验收条件。

## Windows 开发

当前验证基线为 Flutter 3.41.9 / Dart 3.11.5，配合 Visual Studio C++ 桌面工具链。构建工程使用不含中文的路径；本机通过 `D:\project\HanMusic` 目录入口访问原项目。

配置 SDK、Pub 缓存和与锁文件一致的依赖源后，在项目目录运行：

```powershell
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
```

Release 输出为 `build/windows/x64/runner/Release`；运行时保留整个目录，不仅复制 EXE。引入原生插件前，需完成开发者模式及符号链接权限验证。详细操作见环境文档。
