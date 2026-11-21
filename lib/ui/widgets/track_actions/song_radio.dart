import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/l10n.dart';
import '../../../models/track.dart';
import '../../../services/spotify_api_service.dart';
import '../../navigation/app_routes.dart';
import '../toast/app_toast.dart';

/// 「前往歌曲电台」：向 Spotify 取以该曲目为种子的电台歌单，然后打开歌单详情页（可直接播放）。
///
/// 与官方桌面端相同：电台本身就是一张由 Spotify 生成的歌单（`spotify:playlist:37i9…`），
/// 详情页按 id 加载完整曲目与封面。该曲目没有电台或请求失败时弹出提示。
class SongRadio {
  SongRadio._();

  static Future<void> open(BuildContext context, SpotifyTrack track) async {
    final api = context.read<SpotifyApiService>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final l10n = context.l10n;
    try {
      final radio = await api.getSongRadio(track);
      if (context.mounted) AppRoutes.openPlaylist(context, radio);
    } on SpotifyDataException catch (e) {
      final notFound = e.message == '没有找到对应的内容';
      AppToast.showOn(
        messenger,
        notFound ? l10n.radioUnavailable : l10n.radioFailed,
        icon: Icons.sensors_off_rounded,
        tone: notFound ? ToastTone.warning : ToastTone.error,
      );
    }
  }
}
