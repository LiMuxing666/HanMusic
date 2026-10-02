import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:han_music/app/modules/startup/startup_failure_app.dart';
import 'package:han_music/app/modules/startup/startup_loading_app.dart';
import 'package:han_music/app/modules/startup/unsaved_exit_dialog.dart';

void main() {
  testWidgets('startup progress is visible at double text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() async {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.binding.setSurfaceSize(null);
    });
    await tester.pumpWidget(const StartupLoadingApp());
    expect(find.text('正在打开 HanMusic…'), findsOneWidget);
    expect(find.text('正在检查曲库与播放状态，请稍候。'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('locked startup can be read and exited at double text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() async {
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.binding.setSurfaceSize(null);
    });
    var exited = false;
    await tester.pumpWidget(
      StartupFailureApp(
        message: '此数据目录正在被另一个实例使用。请关闭原实例，或选择其他数据目录后重试。',
        dataDirectory: r'D:\中文 空格\音乐播放器\UserData',
        onExit: () => exited = true,
      ),
    );
    expect(find.textContaining('另一个实例'), findsOneWidget);
    expect(find.text(r'D:\中文 空格\音乐播放器\UserData'), findsOneWidget);
    await tester.ensureVisible(find.text('退出'));
    await tester.tap(find.text('退出'));
    expect(exited, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save requires an explicit discard choice', (
    tester,
  ) async {
    bool? allowExit;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              allowExit = await confirmUnsavedExit(context);
            },
            child: const Text('请求退出'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('请求退出'));
    await tester.pumpAndSettle();
    expect(allowExit, isNull);
    await tester.tap(find.text('返回播放器'));
    await tester.pumpAndSettle();
    expect(allowExit, isFalse);
    await tester.tap(find.text('请求退出'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仍然退出'));
    await tester.pumpAndSettle();
    expect(allowExit, isTrue);
  });
}
