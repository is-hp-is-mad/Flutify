import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../l10n/l10n.dart';
import '../../../../services/network/proxy_endpoint.dart';

/// 手动代理的「地址 + 端口」两个输入框。
///
/// 回车或输入框失焦时提交；两项都有效才回调 [onApply]，否则在下方提示且不改动已保存的值。
/// 地址框里直接粘贴「127.0.0.1:7890」「http://host:port」也行：会自动拆出端口。
class ProxyServerFields extends StatefulWidget {
  final String host;
  final int port;
  final void Function(String host, int port) onApply;

  const ProxyServerFields({super.key, required this.host, required this.port, required this.onApply});

  @override
  State<ProxyServerFields> createState() => _ProxyServerFieldsState();
}

class _ProxyServerFieldsState extends State<ProxyServerFields> {
  late final TextEditingController _host = TextEditingController(text: widget.host);
  late final TextEditingController _port = TextEditingController(text: widget.port > 0 ? '${widget.port}' : '');
  final FocusNode _hostFocus = FocusNode();
  final FocusNode _portFocus = FocusNode();
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _hostFocus.addListener(_onFocusChange);
    _portFocus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _hostFocus.dispose();
    _portFocus.dispose();
    super.dispose();
  }

  /// 焦点离开这一组输入框时提交（在两个框之间切换不算离开）。
  void _onFocusChange() {
    if (_hostFocus.hasFocus || _portFocus.hasFocus) return;
    _submit();
  }

  void _submit() {
    var host = _host.text.trim();
    var portText = _port.text.trim();
    // 地址框里带了端口：拆出来回填到端口框（裸 IPv6 地址解析不出端口，会原样保留）
    final pasted = host.contains(':') ? ProxyEndpoint.tryParse(host) : null;
    if (pasted != null) {
      host = pasted.host;
      portText = '${pasted.port}';
      _host.text = host;
      _port.text = portText;
    }
    if (host.isEmpty && portText.isEmpty) {
      setState(() => _invalid = false);
      return;
    }
    final bracketed = host.contains(':') && !host.startsWith('[') ? '[$host]' : host;
    final endpoint = ProxyEndpoint.tryParse('$bracketed:$portText');
    setState(() => _invalid = endpoint == null);
    if (endpoint != null) widget.onApply(endpoint.host, endpoint.port);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    InputDecoration decoration(String hint) => InputDecoration(
      hintText: hint,
      isDense: true,
      filled: true,
      fillColor: theme.colorScheme.surfaceContainerHighest,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('proxy-host'),
                controller: _host,
                focusNode: _hostFocus,
                decoration: decoration(l10n.settingsProxyHostHint),
                keyboardType: TextInputType.url,
                autocorrect: false,
                onSubmitted: (_) => _submit(),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 88,
              child: TextField(
                key: const ValueKey('proxy-port'),
                controller: _port,
                focusNode: _portFocus,
                decoration: decoration(l10n.settingsProxyPortHint),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(5)],
                onSubmitted: (_) => _submit(),
              ),
            ),
          ],
        ),
        if (_invalid) ...[
          const SizedBox(height: 6),
          Text(l10n.settingsProxyInvalid, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}
