import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/l10n.dart';
import '../../services/updates/update_release.dart';
import '../../services/updates/update_service.dart';
import 'package:material_3_expressive/material_3_expressive.dart' show M3EButton, M3EButtonStyle;
import 'flutify_dialog.dart';
import 'flutify_progress.dart';

Future<void> showUpdateDialog(BuildContext context, UpdateService service) => showDialog<void>(
  context: context,
  builder: (_) => ListenableBuilder(
    listenable: service,
    builder: (context, _) {
      final l = context.l10n;
      final release = service.release;
      final ready = service.status == UpdateStatus.ready;
      final android = service.target?.platform == UpdatePlatform.android;
      return FlutifyDialog(
        icon: Icon(ready ? Icons.download_done_rounded : Icons.system_update_rounded),
        title: '${ready ? l.updatesReady : l.updatesAvailable} ${release?.tag ?? ''}',
        // SelectableText / 进度条需要 Material 祖先
        content: Material(type: MaterialType.transparency, child: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ready) ...[
                  Text(android ? l.updatesAndroidHint : l.updatesReadyHint),
                  const SizedBox(height: 16),
                ],
                Text(l.updatesNotes, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                SelectableText(release?.notes.isNotEmpty == true ? release!.notes : l.updatesNoNotes),
                const SizedBox(height: 16),
                UpdateProgress(service: service),
                if (!service.canDownload) Text(l.updatesUnsupported),
                if (service.needsInstallPermission) Text(l.updatesPermission),
                if (service.error != null) Text(l.updatesFailed, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                M3EButton.icon(style: M3EButtonStyle.text,
                  onPressed: () => openUpdatePage(context, service),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(l.updatesPage),
                ),
              ],
            ),
          ),
        )),
        actions: [
          M3EButton.text(onPressed: () => Navigator.pop(context), child: Text(l.updatesLater)),
          if (service.status != UpdateStatus.installing)
            M3EButton.text(onPressed: () { unawaited(service.skip()); Navigator.pop(context); }, child: Text(l.updatesSkip)),
          if (service.status == UpdateStatus.downloading)
            M3EButton.text(onPressed: service.cancelDownload, child: Text(l.commonCancel)),
          if (ready)
            M3EButton.icon(style: M3EButtonStyle.filled,onPressed: service.install, icon: const Icon(Icons.install_mobile_rounded),
              label: Text(android ? l.updatesInstallApk : l.updatesInstall)),
          if (!ready && !service.busy && service.canDownload)
            M3EButton.icon(style: M3EButtonStyle.filled,onPressed: service.download, icon: const Icon(Icons.download_rounded), label: Text(l.updatesDownload)),
        ],
      );
    },
  ),
);

Future<void> openUpdatePage(BuildContext context, UpdateService service) async {
  try {
    final opened = await launchUrl(service.release?.page ?? Uri.parse('https://github.com/is-hp-is-mad/Flutify/releases'),
        mode: LaunchMode.externalApplication);
    if (opened) return;
  } catch (_) {}
  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.updatesFailed)));
}

class UpdateProgress extends StatelessWidget {
  final UpdateService service;
  const UpdateProgress({super.key, required this.service});
  @override
  Widget build(BuildContext context) {
    if (service.status != UpdateStatus.downloading && service.status != UpdateStatus.installing) return const SizedBox.shrink();
    final downloading = service.status == UpdateStatus.downloading;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(downloading ? context.l10n.updatesDownloading : context.l10n.updatesInstalling),
        const SizedBox(height: 8),
        FlutifyLinearProgress(value: downloading ? service.progress : null),
        if (downloading) Text('${(service.received / 1048576).toStringAsFixed(1)} / ${(service.total / 1048576).toStringAsFixed(1)} MB'),
      ]),
    );
  }
}

/// A persistent home-route binding: notifications use a non-modal banner so
/// playback and the currently open route remain usable while downloading.
class UpdatePromptBinding extends StatefulWidget {
  final Widget child;
  const UpdatePromptBinding({super.key, required this.child});
  @override
  State<UpdatePromptBinding> createState() => _UpdatePromptBindingState();
}

class _UpdatePromptBindingState extends State<UpdatePromptBinding> with WidgetsBindingObserver {
  UpdateService? _service;
  int _seen = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final service = context.read<UpdateService?>();
    if (identical(service, _service)) return;
    _service?.removeListener(_changed);
    _service = service;
    service?.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) service?.start(); });
  }
  void _changed() {
    final service = _service!;
    if (service.notification == _seen || service.mode == UpdateMode.disabled) return;
    _seen = service.notification;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || service.release == null || service.mode == UpdateMode.disabled) return;
      final l = context.l10n;
      final ready = service.status == UpdateStatus.ready;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        duration: const Duration(seconds: 15),
        content: Text('${ready ? l.updatesReady : l.updatesAvailable} ${service.release!.tag}'),
        action: SnackBarAction(label: l.updatesDetails, onPressed: () => showUpdateDialog(context, service)),
      ));
    });
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_service?.check());
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service?.removeListener(_changed);
    super.dispose();
  }
  @override
  Widget build(BuildContext context) => widget.child;
}
