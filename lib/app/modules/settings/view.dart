import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../data/models/app_settings.dart';
import '../../data/models/library_sort.dart';
import '../../data/repositories/app_state_store.dart';
import '../../services/app_persistence_service.dart';
import '../player/controller.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final PlayerController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _saving = false;
  String? _notice;
  PlayerController get controller => widget.controller;
  AppPersistenceService? get _persistence =>
      Get.isRegistered<AppPersistenceService>()
      ? Get.find<AppPersistenceService>()
      : null;

  bool _active(int generation) =>
      mounted &&
      controller.acceptsPlaybackCommands &&
      controller.commandGeneration == generation;

  Future<void> _save() async {
    final persistence = _persistence;
    if (_saving || persistence == null || !controller.acceptsPlaybackCommands) {
      return;
    }
    final generation = controller.commandGeneration;
    setState(() {
      _saving = true;
      _notice = null;
    });
    final saved = await persistence.flush();
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (_active(generation)) {
        _notice = saved ? '设置与播放状态已保存。' : '保存失败，请检查数据目录的空间与权限后重试。';
      }
    });
  }

  Future<void> _resetAppearance() async {
    if (!controller.acceptsPlaybackCommands || controller.settings == null) {
      return;
    }
    final generation = controller.commandGeneration;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('恢复显示默认设置？'),
        content: const Text('恢复为浅色主题、导入顺序和升序排列。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('settings-confirm-reset'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (accepted == true && _active(generation)) {
      controller.settings!.restore(const AppSettings());
      setState(() => _notice = '已恢复显示默认设置。');
    }
  }

  Future<void> _copyDataPath(String dataPath) async {
    if (!controller.acceptsPlaybackCommands) return;
    final generation = controller.commandGeneration;
    try {
      await Clipboard.setData(ClipboardData(text: dataPath));
      if (_active(generation)) {
        setState(() => _notice = '已复制数据目录路径。');
      }
    } catch (_) {
      if (_active(generation)) {
        setState(() => _notice = '暂时无法复制路径，请直接选中路径复制。');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Obx(() {
    final settings = controller.settings;
    final themeMode = settings?.settings.value.themeMode ?? ThemeMode.light;
    final ready = controller.acceptsPlaybackCommands && !_saving;
    final store = _persistence?.store;
    final dataPath = store is FileAppStateStore ? store.directory.path : null;
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      key: const Key('settings-scroll'),
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('设置', style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('调整外观与播放偏好，设置会自动保存。'),
              const SizedBox(height: 20),
              _SettingsSection(
                title: '外观',
                children: [
                  const Text('主题'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (mode, label, icon) in [
                        (ThemeMode.light, '浅色', Icons.light_mode_outlined),
                        (ThemeMode.dark, '深色', Icons.dark_mode_outlined),
                        (
                          ThemeMode.system,
                          '跟随系统',
                          Icons.brightness_auto_outlined,
                        ),
                      ])
                        ChoiceChip(
                          key: ValueKey('settings-theme-${mode.name}'),
                          avatar: Icon(icon, size: 18),
                          label: Text(label),
                          selected: themeMode == mode,
                          onSelected: ready && settings != null
                              ? (_) {
                                  if (controller.acceptsPlaybackCommands) {
                                    settings.setThemeMode(mode);
                                  }
                                }
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('选择“跟随系统”后，外观会随系统的浅色或深色模式变化。'),
                ],
              ),
              _SettingsSection(
                title: '曲库',
                children: [
                  DropdownButtonFormField<LibrarySort>(
                    key: ValueKey(
                      'settings-sort-${controller.librarySort.value.name}',
                    ),
                    initialValue: controller.librarySort.value,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '曲库排序'),
                    items: [
                      for (final sort in LibrarySort.values)
                        DropdownMenuItem(value: sort, child: Text(sort.label)),
                    ],
                    onChanged: ready
                        ? (value) {
                            if (value != null &&
                                controller.acceptsPlaybackCommands) {
                              controller.setLibrarySort(value);
                            }
                          }
                        : null,
                  ),
                  SwitchListTile.adaptive(
                    key: const Key('settings-sort-descending'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('降序排列'),
                    value: controller.librarySortDescending.value,
                    onChanged: ready
                        ? (value) {
                            if (controller.acceptsPlaybackCommands) {
                              controller.librarySortDescending.value = value;
                            }
                          }
                        : null,
                  ),
                  const Text('排序会在重启后恢复；曲库工具栏中的调整也会同步到这里。'),
                ],
              ),
              _SettingsSection(
                title: '播放',
                children: [
                  SwitchListTile.adaptive(
                    key: const Key('settings-skip-errors'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('播放失败时自动跳过'),
                    subtitle: const Text('关闭后停在失败歌曲，可手动重试或切换歌曲。'),
                    value: controller.skipOnError.value,
                    onChanged: ready
                        ? (value) {
                            if (controller.acceptsPlaybackCommands) {
                              controller.skipOnError.value = value;
                            }
                          }
                        : null,
                  ),
                  const Text('启动时恢复上次音量与进度，并保持暂停。'),
                ],
              ),
              _SettingsSection(
                title: '数据与保存',
                children: [
                  Text(
                    '曲库 ${controller.songs.length} 首 · 队列 ${controller.queue.length} 首\n'
                    '歌单 ${controller.playlists.playlists.length} 份 · 历史 ${controller.historyEntries.length} 首',
                    key: const Key('settings-data-counts'),
                  ),
                  const SizedBox(height: 12),
                  if (dataPath != null) ...[
                    const Text('数据目录'),
                    SelectableText(
                      dataPath,
                      key: const Key('settings-data-path'),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        key: const Key('settings-copy-path'),
                        onPressed: ready ? () => _copyDataPath(dataPath) : null,
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('复制目录路径'),
                      ),
                    ),
                  ],
                  const Text('曲库索引、歌单、历史和外观设置保存在本机；源音频保留在原位置。'),
                  if (store?.warning case final warning?) ...[
                    const SizedBox(height: 12),
                    Text(warning, style: TextStyle(color: scheme.error)),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton.icon(
                        key: const Key('settings-save'),
                        onPressed: ready && _persistence != null ? _save : null,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(_saving ? '正在保存…' : '立即保存'),
                      ),
                      TextButton(
                        key: const Key('settings-reset'),
                        onPressed: ready && settings != null
                            ? _resetAppearance
                            : null,
                        child: const Text('恢复显示默认设置'),
                      ),
                    ],
                  ),
                  if (_notice case final notice?) ...[
                    const SizedBox(height: 12),
                    Semantics(liveRegion: true, child: Text(notice)),
                  ],
                ],
              ),
              _SettingsSection(
                title: '关于 HanMusic',
                children: [
                  const Text('0.1.0-rc.2+28 · 开发工作副本'),
                  const SizedBox(height: 8),
                  const Text('本地音乐、自定义网络源、歌单与睡眠定时。'),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('settings-licenses'),
                      onPressed: ready
                          ? () => showLicensePage(
                              context: context,
                              applicationName: 'HanMusic',
                              applicationVersion: '0.1.0-rc.2+28',
                            )
                          : null,
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('查看组件许可'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('此页列出 Flutter 收集的组件许可；完整发行材料见项目随附文档。'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  });
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    ),
  );
}
