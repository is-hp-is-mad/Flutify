import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_info.dart';
import '../../providers/library_provider.dart';
import '../../services/storage_service.dart';
import '../screens/library/playlist_sync_screen.dart';
import 'app_button.dart';
import 'app_modal.dart';
import 'flutify_dialog.dart';
import '../../l10n/l10n.dart';

/// 升级后提示「有歌单没同步到 Spotify」：读到账号歌单列表后，若有只存在本机的歌单，
/// 每个版本最多弹一次；点「去同步」打开 [PlaylistSyncScreen]。设置页「歌单备份」里也有入口。
class PlaylistSyncPromptBinding extends StatefulWidget {
  final Widget child;
  const PlaylistSyncPromptBinding({super.key, required this.child});

  @override
  State<PlaylistSyncPromptBinding> createState() => _PlaylistSyncPromptBindingState();
}

class _PlaylistSyncPromptBindingState extends State<PlaylistSyncPromptBinding> {
  LibraryProvider? _library;
  bool _shown = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final library = context.read<LibraryProvider>();
    if (identical(library, _library)) return;
    _library?.removeListener(_changed);
    _library = library;
    library.addListener(_changed);
    _changed();
  }

  void _changed() {
    final library = _library;
    if (_shown || library == null || library.isLoading) return;
    final count = library.unsyncedPlaylists.length;
    if (count == 0) return;
    final store = context.read<StorageService>().updates;
    if (store.playlistSyncPromptedVersion == AppInfo.releaseTag) {
      _shown = true;
      return;
    }
    _shown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      store.setPlaylistSyncPromptedVersion(AppInfo.releaseTag);
      showAppDialog<void>(
        context: context,
        builder: (dialogContext) => FlutifyDialog(
          icon: const Icon(Icons.cloud_upload_rounded),
          title: dialogContext.l10n.playlistSyncPromptTitle(count),
          content: SizedBox(
            width: 480,
            child: Text(
              dialogContext.l10n.playlistSyncPromptBody,
            ),
          ),
          actions: [
            AppButton.text(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(dialogContext.l10n.playlistSyncPromptLater),
            ),
            AppButton.filled(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                PlaylistSyncScreen.open(context);
              },
              child: Text(dialogContext.l10n.playlistSyncPromptGo),
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    _library?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
