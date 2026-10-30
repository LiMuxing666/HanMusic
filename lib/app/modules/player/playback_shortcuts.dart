import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

/// Playback commands for the active player page, leaving text editing alone.
class PlayerPlaybackShortcuts extends StatelessWidget {
  const PlayerPlaybackShortcuts({
    super.key,
    required this.controller,
    required this.child,
    this.autofocus = true,
  });

  final PlayerController controller;
  final Widget child;
  final bool autofocus;

  static const _bindings = <SingleActivator, _PlaybackCommand>{
    SingleActivator(
      LogicalKeyboardKey.space,
      control: true,
      includeRepeats: false,
    ): _PlaybackCommand.toggle,
    SingleActivator(
      LogicalKeyboardKey.arrowLeft,
      control: true,
      includeRepeats: false,
    ): _PlaybackCommand.previous,
    SingleActivator(
      LogicalKeyboardKey.arrowRight,
      control: true,
      includeRepeats: false,
    ): _PlaybackCommand.next,
    SingleActivator(LogicalKeyboardKey.arrowLeft, control: true, shift: true):
        _PlaybackCommand.backward,
    SingleActivator(LogicalKeyboardKey.arrowRight, control: true, shift: true):
        _PlaybackCommand.forward,
    SingleActivator(LogicalKeyboardKey.arrowUp, control: true):
        _PlaybackCommand.louder,
    SingleActivator(LogicalKeyboardKey.arrowDown, control: true):
        _PlaybackCommand.quieter,
    SingleActivator(
      LogicalKeyboardKey.keyM,
      control: true,
      includeRepeats: false,
    ): _PlaybackCommand.mute,
  };

  bool get _editingText {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null &&
        (focused.widget is EditableText ||
            focused.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  KeyEventResult _handleKey(BuildContext context, KeyEvent event) {
    if (!controller.acceptsPlaybackCommands ||
        ModalRoute.of(context)?.isCurrent == false ||
        _editingText) {
      return KeyEventResult.ignored;
    }
    for (final binding in _bindings.entries) {
      if (binding.key.accepts(event, HardwareKeyboard.instance)) {
        _run(binding.value);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _run(_PlaybackCommand command) {
    switch (command) {
      case _PlaybackCommand.toggle:
        if (controller.canRetryPlayback) {
          unawaited(controller.retryPlayback(controller.currentSong.value!.id));
        } else if (controller.canPlay && !controller.isLoading.value) {
          unawaited(controller.togglePlayback());
        }
      case _PlaybackCommand.previous:
      case _PlaybackCommand.next:
        if (controller.queue.isNotEmpty && !controller.isLoading.value) {
          unawaited(
            command == _PlaybackCommand.previous
                ? controller.previous()
                : controller.next(),
          );
        }
      case _PlaybackCommand.backward:
      case _PlaybackCommand.forward:
        if (controller.canPlay &&
            !controller.isLoading.value &&
            controller.duration.value > Duration.zero) {
          final offset = Duration(
            seconds: command == _PlaybackCommand.backward ? -5 : 5,
          );
          // PlayerService clamps to the current track and guards stale seeks.
          unawaited(controller.seek(controller.position.value + offset));
        }
      case _PlaybackCommand.louder:
      case _PlaybackCommand.quieter:
        unawaited(
          controller.setVolume(
            controller.volume.value +
                (command == _PlaybackCommand.louder ? 0.05 : -0.05),
          ),
        );
      case _PlaybackCommand.mute:
        unawaited(controller.toggleMute());
    }
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: autofocus,
    skipTraversal: true,
    onKeyEvent: (_, event) => _handleKey(context, event),
    child: child,
  );
}

enum _PlaybackCommand {
  toggle,
  previous,
  next,
  backward,
  forward,
  louder,
  quieter,
  mute,
}
