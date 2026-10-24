import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;

/// Connect 设备名输入框：回车或失焦时提交（去掉首尾空格，空值表示恢复默认名）。
class DeviceNameField extends StatefulWidget {
  final String name;
  final String hint;
  final ValueChanged<String> onApply;

  /// 一键填入的候选名（本机设备名，如 LAPTOP-XXXXXX）及按钮文字；为空时不显示按钮。
  final Future<String> Function()? suggestion;
  final String suggestionLabel;

  const DeviceNameField({
    super.key,
    required this.name,
    required this.hint,
    required this.onApply,
    this.suggestion,
    this.suggestionLabel = '',
  });

  @override
  State<DeviceNameField> createState() => _DeviceNameFieldState();
}

class _DeviceNameFieldState extends State<DeviceNameField> {
  late final TextEditingController _controller = TextEditingController(text: widget.name);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _submit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name != widget.name) widget.onApply(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggestion = widget.suggestion;
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: true,
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      ),
      // 服务端对设备名长度有限制，保守取 40
      inputFormatters: [LengthLimitingTextInputFormatter(40)],
      onSubmitted: (_) => _submit(),
    );
    if (suggestion == null) return field;
    return Row(
      children: [
        Expanded(child: field),
        const SizedBox(width: 8),
        M3EButton.text(
          onPressed: () async {
            final name = await suggestion();
            if (!mounted || name.isEmpty) return;
            _controller.text = name;
            _submit();
          },
          child: Text(widget.suggestionLabel),
        ),
      ],
    );
  }
}
