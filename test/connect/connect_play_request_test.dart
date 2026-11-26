import 'package:flutify_app/models/playback_context.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/services/connect/connect_play_request.dart';
import 'package:flutter_test/flutter_test.dart';

SpotifyTrack _t(String id, {String? uri}) => SpotifyTrack(id: id, name: id, uri: uri ?? 'spotify:track:$id');

void main() {
  final tracks = [_t('a'), _t('b'), _t('c')];

  test('歌单 / 专辑 / 艺人：交给远程展开上下文，从点的那首开始', () {
    for (final uri in ['spotify:playlist:p1', 'spotify:album:a1', 'spotify:artist:r1']) {
      final r = ConnectPlayRequest.from(
        context: PlaybackContext(type: 'x', name: 'x', uri: uri),
        tracks: tracks,
        start: tracks[1],
        username: 'me',
      )!;
      expect(r.contextUri, uri);
      expect(r.trackUri, 'spotify:track:b');
      expect(r.trackUris, isEmpty);
    }
  });

  test('用户排过序的歌单（不随机）：带上整个列表而不是上下文 URI', () {
    final ctx = const PlaybackContext.playlist(
      'x',
      uri: 'spotify:playlist:p1',
    ).withReordered(true);

    final whole = ConnectPlayRequest.from(
      context: ctx,
      tracks: tracks,
      username: 'me',
    )!;
    expect(whole.contextUri, isEmpty);
    expect(whole.trackUris, [
      'spotify:track:a',
      'spotify:track:b',
      'spotify:track:c',
    ]);
    expect(whole.trackUri, isNull);
    expect(whole.trackIndex, isNull);

    final fromStart = ConnectPlayRequest.from(
      context: ctx,
      tracks: tracks,
      start: tracks[1],
      username: 'me',
    )!;
    expect(fromStart.trackUris, [
      'spotify:track:a',
      'spotify:track:b',
      'spotify:track:c',
    ]);
    expect(fromStart.trackUri, 'spotify:track:b');
    expect(fromStart.trackIndex, 1);
  });

  test('用户排过序但随机播放：顺序无所谓，仍交给远程展开上下文', () {
    final ctx = const PlaybackContext.playlist(
      'x',
      uri: 'spotify:playlist:p1',
    ).withReordered(true);
    final r = ConnectPlayRequest.from(
      context: ctx,
      tracks: tracks,
      username: 'me',
      shuffle: true,
    )!;
    expect(r.contextUri, 'spotify:playlist:p1');
    expect(r.trackUris, isEmpty);
  });

  test('用户排过序的已点赞歌曲：不走 collection 上下文，带临时列表', () {
    final ctx = const PlaybackContext.collection(
      'Liked',
      uri: 'spotify:collection:tracks',
    ).withReordered(true);
    final r = ConnectPlayRequest.from(
      context: ctx,
      tracks: tracks,
      username: 'me',
    )!;
    expect(r.contextUri, isEmpty);
    expect(r.trackUris, hasLength(3));
  });

  test('从头播放整个上下文：不带 skip_to', () {
    final r = ConnectPlayRequest.from(
      context: const PlaybackContext.album('x', uri: 'spotify:album:a1'),
      tracks: tracks,
      username: 'me',
    )!;
    expect(r.trackUri, isNull);
    expect(r.trackIndex, isNull);
  });

  test('已点赞的歌曲：换成按用户名的 collection；没有用户名时退回临时列表', () {
    const liked = PlaybackContext.collection('Liked', uri: 'spotify:collection:tracks');
    final r = ConnectPlayRequest.from(context: liked, tracks: tracks, start: tracks[2], username: 'me')!;
    expect(r.contextUri, 'spotify:user:me:collection');
    expect(r.trackUri, 'spotify:track:c');

    final noUser = ConnectPlayRequest.from(context: liked, tracks: tracks, start: tracks[2], username: '')!;
    expect(noUser.contextUri, isEmpty);
    expect(noUser.trackUris, hasLength(3));
  });

  test('搜索结果 / 无上下文：临时列表，从点的那首的下标开始', () {
    final r = ConnectPlayRequest.from(
      context: const PlaybackContext.search('q'),
      tracks: tracks,
      start: tracks[1],
      username: 'me',
    )!;
    expect(r.contextUri, isEmpty);
    expect(r.trackUris, ['spotify:track:a', 'spotify:track:b', 'spotify:track:c']);
    expect(r.trackIndex, 1);

    final single = ConnectPlayRequest.from(
      context: PlaybackContext.none,
      tracks: const [],
      start: _t('z'),
      username: 'me',
    )!;
    expect(single.trackUris, ['spotify:track:z']);
    expect(single.trackIndex, 0);
  });

  test('没有 Spotify URI 的曲目被跳过；起始曲目没有时返回 null（本机播放）', () {
    final odd = _t('x', uri: 'file:///x.mp3');
    final r = ConnectPlayRequest.from(
      context: PlaybackContext.none,
      tracks: [tracks[0], odd, tracks[1]],
      start: tracks[1],
      username: 'me',
    )!;
    expect(r.trackUris, ['spotify:track:a', 'spotify:track:b']);
    expect(r.trackIndex, 1);

    expect(ConnectPlayRequest.from(context: PlaybackContext.none, tracks: [odd], start: odd, username: 'me'), isNull);
  });

  test('超长列表：以起始曲目为首截取', () {
    final many = [for (var i = 0; i < 800; i++) _t('t$i')];
    final r = ConnectPlayRequest.from(context: PlaybackContext.none, tracks: many, start: many[600], username: 'me')!;
    expect(r.trackUris, hasLength(200));
    expect(r.trackUris.first, 'spotify:track:t600');
    expect(r.trackIndex, 0);
  });
}
