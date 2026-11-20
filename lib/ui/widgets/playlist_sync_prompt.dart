import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_info.dart';
import '../../providers/library_provider.dart';
import '../../services/storage_service.dart';
import '../screens/library/playlist_sync_screen.dart';
import 'app_button.dart';
import 'app_modal.dart';
import 'flutify_dialog.dart';

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
          title: '有 $count 个歌单没有同步到 Spotify',
          content: const SizedBox(
            width: 480,
            child: Text(
              '旧版本的问题：在 Flutify 里收藏、新建或从备份导入的歌单只保存在本机，'
              '没有写进你的 Spotify 账号，官方客户端和网页版的音乐库里看不到。'
              '这个版本已修复，收藏 / 取消收藏会同步到账号；之前遗留的歌单可以现在补同步。\n\n'
              '以后也可以在「设置 → 歌单备份」里找到这个入口。',
            ),
          ),
          actions: [
            AppButton.text(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('以后再说'),
            ),
            AppButton.filled(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                PlaylistSyncScreen.open(context);
              },
              child: const Text('去同步'),
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
