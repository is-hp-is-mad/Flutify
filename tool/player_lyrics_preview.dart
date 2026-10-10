// Offline Android visual fixture. Not imported by the production entry point.
import 'dart:async';

import 'package:flutify_app/core/theme/md3e_theme.dart';
import 'package:flutify_app/l10n/l10n.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/image.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/providers/preferences_provider.dart';
import 'package:flutify_app/providers/spotify_provider.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/fakes/fake_audio_player_service.dart';
import '../test/fakes/fake_spotify_api_service.dart';
import '../test/fakes/fake_track_audio_source.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // This offline fixture must never read or modify an installed account's prefs.
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final track = SpotifyTrack(
    id: 'lyrics-scene-preview',
    uri: 'spotify:track:lyrics-scene-preview',
    name: '渐入夜色 · Into the Evening',
    artists: const [SpotifyArtist(id: 'preview', name: 'Flutify Studio')],
    album: SpotifyAlbum(
      id: 'preview',
      name: 'Motion Study',
      images: const [
        SpotifyImage(url: 'http://127.0.0.1:8766/flutify_logo_1024.png'),
      ],
    ),
    durationMs: 65000,
  );
  const lyrics = SpotifyLyrics(
    language: 'en',
    lines: [
      LyricLine(startTimeMs: 8000, words: 'The city settles into blue'),
      LyricLine(startTimeMs: 16000, words: 'A quiet road beneath our feet'),
      LyricLine(startTimeMs: 24000, words: 'We follow every passing light'),
      LyricLine(startTimeMs: 32000, words: ''),
      LyricLine(startTimeMs: 42000, words: 'And leave the restless day behind'),
      LyricLine(startTimeMs: 50000, words: 'Another moment slowly opens'),
      LyricLine(
        startTimeMs: 58000,
        words: 'There is still a little room to dream',
      ),
    ],
    alternatives: [
      LyricsAlternative(
        language: 'zh-Hans',
        lines: [
          '城市渐渐染上蓝色',
          '脚下是安静的路',
          '我们追随经过的灯光',
          '',
          '把喧嚣的一天留在身后',
          '又一个瞬间缓缓展开',
          '还留有一点做梦的空间',
        ],
      ),
    ],
  );
  final audio = PlayerPreviewAudio();
  final playback = PlaybackProvider(
    audio,
    storage,
    audioLoader: FakeTrackAudioSource(),
  );
  final spotify = SpotifyProvider(
    FakeSpotifyApiService(storage, lyricsById: {track.id: lyrics}),
    storage,
  );
  await playback.playTrack(
    track,
    contextQueue: [
      track,
      for (var i = 1; i <= 12; i++)
        SpotifyTrack(
          id: 'queue-preview-$i',
          name: 'Night Walk · 预览曲目 $i',
          artists: track.artists,
          album: track.album,
          durationMs: 180000,
        ),
    ],
  );
  audio.durationController.add(audio.duration);
  audio.stateController.add(PlayerState(true, ProcessingState.ready));
  Timer.periodic(const Duration(milliseconds: 250), (_) => audio.advance());
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: playback),
        ChangeNotifierProvider.value(value: spotify),
        ChangeNotifierProvider(create: (_) => PreferencesProvider(storage)),
        ChangeNotifierProvider(create: (_) => LibraryProvider(storage)),
      ],
      child: MaterialApp(
        theme: MD3ETheme.dark,
        locale: const Locale('zh'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        debugShowCheckedModeBanner: false,
        home: const Scaffold(body: FullPlayerSheet(fullscreen: true)),
      ),
    ),
  );
}

/// A seek-aware synthetic clock; never included in the production entry point.
class PlayerPreviewAudio extends FakeAudioPlayerService {
  Duration _position = Duration.zero;

  @override
  Duration get position => _position;

  @override
  Duration get duration => const Duration(seconds: 65);

  void advance() {
    if (!isPlaying) return;
    _position += const Duration(milliseconds: 250);
    if (_position >= duration) _position = Duration.zero;
    positionController.add(_position);
  }

  @override
  Future<void> seek(Duration position) async {
    _position = Duration(
      microseconds: position.inMicroseconds.clamp(0, duration.inMicroseconds),
    );
    await super.seek(_position);
    positionController.add(_position);
  }

  @override
  Future<void> play() async {
    await super.play();
    stateController.add(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    await super.pause();
    stateController.add(PlayerState(false, ProcessingState.ready));
  }
}
