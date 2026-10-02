import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Search input shared by the library and online pages.
class MusicSearchField extends StatefulWidget {
  const MusicSearchField({
    super.key,
    required this.inputKey,
    required this.query,
    required this.onChanged,
    this.onSubmitted,
    this.enabled = true,
  });

  final ValueKey<String> inputKey;
  final String query;
  final ValueChanged<String> onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;

  @override
  State<MusicSearchField> createState() => MusicSearchFieldState();
}

class MusicSearchFieldState extends State<MusicSearchField> {
  late final TextEditingController _text;
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.query);
  }

  @override
  void didUpdateWidget(covariant MusicSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Preserve selection and IME composition for ordinary typing. Only replace
    // the editing value when the owning page supplies a different query.
    if (_text.text != widget.query) {
      _text.value = TextEditingValue(
        text: widget.query,
        selection: TextSelection.collapsed(offset: widget.query.length),
      );
    }
  }

  void focusAndSelect() {
    if (!widget.enabled) return;
    _focus.requestFocus();
    _text.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _text.text.length,
    );
  }

  void _clear() {
    if (!widget.enabled) return;
    _text.clear();
    widget.onChanged('');
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
    child: ValueListenableBuilder<TextEditingValue>(
      valueListenable: _text,
      builder: (context, value, _) => TextFormField(
        key: widget.inputKey,
        controller: _text,
        focusNode: _focus,
        enabled: widget.enabled,
        onChanged: widget.onChanged,
        onFieldSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          hintText: '搜索歌曲、歌手或专辑',
          prefixIcon: const Icon(Icons.search_rounded),
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  key: ValueKey('${widget.inputKey.value}-clear'),
                  tooltip: '清空搜索（Esc）',
                  onPressed: widget.enabled ? _clear : null,
                  icon: const Icon(Icons.close_rounded),
                ),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 13,
          ),
        ),
      ),
    ),
  );
}
