import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton;
import 'flutify_dialog.dart';

/// 「为歌单命名」对话框。返回输入的名称，取消时返回 null。
///
/// [initialName] 为空时使用本地化的默认名「我的歌单」。
class CreatePlaylistDialog extends StatefulWidget {
  final String? initialName;

  const CreatePlaylistDialog({super.key, this.initialName});

  static Future<String?> show(BuildContext context, {String? initialName}) {
    return showDialog<String>(
      context: context,
      builder: (_) => CreatePlaylistDialog(initialName: initialName),
    );
  }

  @override
  State<CreatePlaylistDialog> createState() => _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends State<CreatePlaylistDialog> {
  late final String _initialName = widget.initialName ?? context.l10n.createPlaylistDefaultName;
  late final TextEditingController _controller = TextEditingController(text: _initialName)
    ..selection = TextSelection(baseOffset: 0, extentOffset: _initialName.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return FlutifyDialog(
      title: l10n.createPlaylistTitle,
      content: Material(type: MaterialType.transparency, child: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(hintText: l10n.createPlaylistHint),
      )),
      actions: [
        M3EButton.text(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
        M3EButton.filled(onPressed: _submit, child: Text(l10n.commonCreate)),
      ]);
  }
}
