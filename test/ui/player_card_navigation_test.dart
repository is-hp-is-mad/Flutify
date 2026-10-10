import 'dart:async';

import 'package:flutify_app/core/utils/artwork_palette.dart';
import 'package:flutify_app/main.dart';
import 'package:flutify_app/models/album.dart';
import 'package:flutify_app/models/artist.dart';
import 'package:flutify_app/models/image.dart';
import 'package:flutify_app/models/lyrics.dart';
import 'package:flutify_app/models/track.dart';
import 'package:flutify_app/providers/library_provider.dart';
import 'package:flutify_app/providers/playback_provider.dart';
import 'package:flutify_app/services/eme/eme_player.dart';
import 'package:flutify_app/services/storage_service.dart';
import 'package:flutify_app/ui/navigation/app_routes.dart';
import 'package:flutify_app/ui/screens/detail/album_detail_screen.dart';
import 'package:flutify_app/ui/screens/detail/artist_detail_screen.dart';
import 'package:flutify_app/ui/screens/main_shell.dart';
import 'package:flutify_app/ui/screens/player/android_player_scene.dart';
import 'package:flutify_app/ui/screens/player/device_picker_sheet.dart';
import 'package:flutify_app/ui/screens/player/full_player_sheet.dart';
import 'package:flutify_app/ui/screens/player/player_destinations_sheet.dart';
import 'package:flutify_app/ui/widgets/marquee_text.dart';
import 'package:flutify_app/ui/widgets/cover_image.dart';
import 'package:flutify_app/ui/widgets/player_controls.dart';
import 'package:flutify_app/ui/widgets/playback_scrubber.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_audio_player_service.dart';
import '../fakes/fake_spotify_api_service.dart';
import '../fakes/fake_track_audio_source.dart';

const _artist = SpotifyArtist(id: 'card-artist', name: 'Card Artist');
const _guest = SpotifyArtist(id: 'card-guest', name: 'Guest Artist');
const _album = SpotifyAlbum(id: 'card-album', name: 'Card Album');
const _previousAlbum = SpotifyAlbum(id: 'previous', name: 'Previous Album');
const _track = SpotifyTrack(
  id: 'card-track',
  name: 'Card Song',
  artists: [_artist, _guest],
  album: _album,
  durationMs: 180000,
);

Future<void> _frames(WidgetTester tester, [int count = 8]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Finder _inPlayer(Finder finder) =>
    find.descendant(of: find.byType(FullPlayerSheet), matching: finder);

class _ArtistApi extends FakeSpotifyApiService {
  _ArtistApi(
    super.storage, {
    required super.lyricsById,
    this.details = const {},
  });

  final Map<String, Future<SpotifyArtist>> details;
  final List<String> artistRequests = [];

  @override
  Future<SpotifyArtist> getArtist(String id) {
    artistRequests.add(id);
    return details[id] ?? super.getArtist(id);
  }
}

Future<
  ({PlaybackProvider playback, FakeAudioPlayerService audio, _ArtistApi api})
>
_open(
  WidgetTester tester, {
  SpotifyTrack track = _track,
  bool lyrics = true,
  double width = 390,
  double height = 844,
  Map<String, Future<SpotifyArtist>> artistDetails = const {},
}) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  final paletteEnabled = ArtworkPalette.enabled;
  ArtworkPalette.enabled = false;
  addTearDown(() => ArtworkPalette.enabled = paletteEnabled);
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final storage = await StorageService.init();
  final audio = FakeAudioPlayerService();
  final api = _ArtistApi(
    storage,
    details: artistDetails,
    lyricsById: {
      track.id: SpotifyLyrics(
        language: 'en',
        lines: List.generate(
          40,
          (i) => LyricLine(
            startTimeMs: i * 4000,
            words: 'A seekable lyric line $i',
          ),
        ),
      ),
    },
  );
  await tester.pumpWidget(
    FlutifyApp(
      storageService: storage,
      audioEngine: audio,
      emePlayer: EmePlayer(),
      spotifyApiService: api,
      trackAudioLoader: FakeTrackAudioSource(),
    ),
  );
  await _frames(tester);
  final context = tester.element(find.byType(MainShell));
  final playback = context.read<PlaybackProvider>();
  await playback.playTrack(track);
  audio.durationController.add(const Duration(minutes: 3));
  audio.positionController.add(const Duration(seconds: 30));
  audio.stateController.add(PlayerState(true, ProcessingState.ready));
  AppRoutes.openAlbum(context, _previousAlbum);
  await _frames(tester);
  FullPlayerSheet.show(tester.element(find.byType(MainShell)));
  await _frames(tester);
  if (lyrics) {
    await tester.tap(_inPlayer(find.byTooltip('歌词')));
    await _frames(tester);
  }
  audio.seeks.clear();
  return (playback: playback, audio: audio, api: api);
}

Future<void> _unmount(WidgetTester tester) async {
  Navigator.of(
    tester.element(find.byType(MainShell, skipOffstage: false)),
    rootNavigator: true,
  ).popUntil((route) => route.isFirst);
  await _frames(tester);
  await tester.pumpWidget(const SizedBox.shrink());
  await _frames(tester);
  debugDefaultTargetPlatformOverride = null;
}

void main() {
  testWidgets(
    'details controls keep their original style and morph into the card',
    (tester) async {
      final session = await _open(tester, lyrics: false);
      final play = _inPlayer(find.byType(PlayPauseButton));
      final scrubber = _inPlayer(find.byType(PlaybackScrubber));
      final slider = find.descendant(
        of: scrubber,
        matching: find.byType(Slider),
      );
      final label = find.descendant(of: scrubber, matching: find.text('0:30'));
      final playElement = tester.element(play);
      final sliderElement = tester.element(slider);
      final scrubberState = tester.state(scrubber);
      final detail = tester.widget<PlayPauseButton>(play);
      expect(detail.size, 60);
      expect(detail.iconSize, 34);
      expect(detail.background, Colors.white);
      expect(detail.foreground, Colors.black);
      expect(detail.backgroundAnimationDuration, Duration.zero);
      expect(
        tester.getCenter(label).dy,
        greaterThan(tester.getCenter(slider).dy + 20),
      );
      final detailSlider = tester.getRect(slider);

      await tester.tap(_inPlayer(find.byTooltip('歌词')));
      await tester.pump();
      expect(
        tester.widget<PlayPauseButton>(play).size,
        60,
        reason: 'no click-frame style jump',
      );
      await tester.pump(const Duration(milliseconds: 120));
      final moving = tester.widget<PlayPauseButton>(play);
      expect(moving.size, inExclusiveRange(52, 60));
      expect(moving.iconSize, inExclusiveRange(34, 44));
      expect(moving.background.a, inExclusiveRange(0, 1));
      expect(tester.getRect(slider).width, lessThan(detailSlider.width));
      final beforeReverse = tester.getRect(slider);
      await tester.tap(_inPlayer(find.byTooltip('歌词')));
      await tester.pump();
      expect(tester.getRect(slider), rectMoreOrLessEquals(beforeReverse));
      await _frames(tester);
      expect(tester.widget<PlayPauseButton>(play).background, Colors.white);

      await tester.tap(_inPlayer(find.byTooltip('歌词')));
      await _frames(tester);
      final card = tester.widget<PlayPauseButton>(play);
      expect(card.size, 52);
      expect(card.iconSize, 44);
      expect(card.background.a, 0);
      expect(card.foreground, Colors.white);
      expect(
        tester.getCenter(label).dy,
        closeTo(tester.getCenter(slider).dy, 0.1),
      );
      expect(tester.element(play), same(playElement));
      expect(tester.element(slider), same(sliderElement));
      expect(tester.state(scrubber), same(scrubberState));
      expect(session.audio.seeks, isEmpty);
      expect(session.playback.isPlaying, isTrue);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  for (final size in [const Size(320, 568), const Size(740, 390)]) {
    testWidgets(
      'real controls reflow and reverse from idle at $size with 2x text',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _open(
          tester,
          lyrics: false,
          width: size.width,
          height: size.height,
        );
        final play = _inPlayer(find.byType(PlayPauseButton));
        final slider = _inPlayer(find.byType(Slider));
        final playElement = tester.element(play);
        final sliderElement = tester.element(slider);
        await tester.tap(_inPlayer(find.byTooltip('歌词')));
        await tester.pump();
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(slider), same(sliderElement));
          expect(tester.getRect(play).right, lessThanOrEqualTo(size.width));
          expect(tester.getRect(play).bottom, lessThan(size.height));
          expect(tester.takeException(), isNull);
        }
        // Let the last animation tick settle before starting the idle clock.
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(seconds: 4));
        await _frames(tester, 4);
        expect(play.hitTestable(), findsNothing);
        await tester.tap(_inPlayer(find.byTooltip('歌词')));
        await tester.pump();
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(tester.element(play), same(playElement));
          expect(tester.takeException(), isNull);
        }
        expect(play.hitTestable(), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 16));
        expect(tester.widget<PlayPauseButton>(play).size, 60);
        await _unmount(tester);
      },
    );
  }

  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets('folded footer blank space only reveals the card at $width', (
      tester,
    ) async {
      final session = await _open(tester, width: width);
      final header = find.byKey(const ValueKey('player-card-title'));
      final device = _inPlayer(find.byIcon(Icons.devices_rounded));
      final deviceText = _inPlayer(find.text('正在本设备上收听'));
      final lyrics = _inPlayer(find.byTooltip('歌词'));
      for (final fraction in [.25, .5, .75]) {
        await tester.pump(const Duration(seconds: 4));
        await _frames(tester, 4);
        expect(header.hitTestable(), findsNothing);
        final label = tester.getRect(deviceText);
        final gapStart = label.right + 12;
        final gapEnd = tester.getRect(lyrics).left - 8;
        expect(gapEnd, greaterThan(gapStart));
        final point = Offset(
          gapStart + (gapEnd - gapStart) * fraction,
          tester.getCenter(device).dy,
        );
        await tester.tapAt(point);
        await _frames(tester, 4);
        expect(find.byType(DevicePickerSheet), findsNothing);
        expect(header.hitTestable(), findsOneWidget);
        expect(session.audio.seeks, isEmpty);
        expect(session.playback.position, const Duration(seconds: 30));
        expect(session.playback.isPlaying, isTrue);
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  testWidgets('folded footer buttons still act on their first tap', (
    tester,
  ) async {
    final session = await _open(tester);
    final device = _inPlayer(find.byIcon(Icons.devices_rounded));
    final deviceButton = find
        .ancestor(of: device, matching: find.byType(InkWell))
        .first;
    expect(tester.getSize(deviceButton).height, greaterThanOrEqualTo(48));
    await tester.pump(const Duration(seconds: 4));
    await _frames(tester, 4);
    await tester.tap(device);
    await _frames(tester, 4);
    expect(find.byType(DevicePickerSheet), findsOneWidget);
    Navigator.of(
      tester.element(find.byType(DevicePickerSheet)),
      rootNavigator: true,
    ).pop();
    await _frames(tester, 4);
    await tester.pump(const Duration(seconds: 4));
    await _frames(tester, 4);
    await tester.tap(_inPlayer(find.byTooltip('歌词')));
    await _frames(tester);
    expect(
      tester
          .widget<AndroidPlayerScene>(find.byType(AndroidPlayerScene))
          .lyricsMode,
      isFalse,
    );
    await tester.tap(_inPlayer(find.byTooltip('播放队列')));
    await _frames(tester);
    expect(
      tester
          .widget<AndroidPlayerScene>(find.byType(AndroidPlayerScene))
          .queueMode,
      isTrue,
    );
    expect(session.audio.seeks, isEmpty);
    expect(session.playback.isPlaying, isTrue);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  for (final textScale in [1.0, 1.6]) {
    testWidgets(
      'metadata typography shares cover progress without remounting at $textScale',
      (tester) async {
        tester.platformDispatcher.textScaleFactorTestValue = textScale;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await _open(tester, lyrics: false);
        final title = _inPlayer(find.byType(MarqueeText));
        final artist = _inPlayer(find.text(_track.artistNames));
        final titleElement = tester.element(title);
        final artistElement = tester.element(artist);
        final originalSize = tester.widget<MarqueeText>(title).style!.fontSize!;
        final originalArtistRect = tester.getRect(artist);
        final cover = _inPlayer(find.byType(Hero));
        final largeCover = tester.getRect(cover);

        await tester.tap(_inPlayer(find.byTooltip('歌词')));
        await tester.pump();
        expect(
          tester.widget<MarqueeText>(title).style!.fontSize,
          originalSize,
          reason: 'a mode change must not immediately switch to the small font',
        );
        expect(tester.element(title), same(titleElement));
        expect(tester.element(artist), same(artistElement));
        final samples = <(double, Rect, Rect)>[];
        for (var frame = 0; frame < 40; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          final progress = tester
              .widget<Opacity>(
                find.byKey(const ValueKey('lyrics-background-blend')),
              )
              .opacity;
          expect(
            tester.widget<MarqueeText>(title).style!.fontSize,
            closeTo(originalSize * (1 - 0.35 * progress), 0.001),
          );
          expect(tester.element(title), same(titleElement));
          expect(tester.element(artist), same(artistElement));
          samples.add((
            progress,
            tester.getRect(cover),
            tester.getRect(artist),
          ));
        }
        final smallCover = tester.getRect(cover);
        final cardArtistRect = tester.getRect(artist);
        for (final (progress, rect, artistRect) in samples) {
          expect(
            rect,
            rectMoreOrLessEquals(Rect.lerp(largeCover, smallCover, progress)!),
          );
          expect(
            artistRect,
            rectMoreOrLessEquals(
              Rect.lerp(originalArtistRect, cardArtistRect, progress)!,
            ),
            reason:
                'artist travels with controls; its baseline must not jump during reflow',
          );
        }

        await tester.tap(_inPlayer(find.byTooltip('歌词')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 96));
        final reversingFont = tester.widget<MarqueeText>(title).style!.fontSize;
        final reversingTitle = tester.getRect(title);
        final reversingArtist = tester.getRect(artist);
        await tester.tap(_inPlayer(find.byTooltip('歌词')));
        await tester.pump();
        expect(
          tester.widget<MarqueeText>(title).style!.fontSize,
          reversingFont,
        );
        expect(tester.getRect(title), reversingTitle);
        expect(tester.getRect(artist), reversingArtist);
        expect(tester.element(title), same(titleElement));
        await _unmount(tester);
      },
    );
  }

  testWidgets('lyrics card cover returns to artwork without seeking', (
    tester,
  ) async {
    final session = await _open(tester);
    final cover = _inPlayer(find.byType(Hero));
    expect(tester.getSize(cover).width, lessThan(70));

    await tester.tapAt(tester.getCenter(cover));
    await _frames(tester);

    expect(
      tester
          .widget<AndroidPlayerScene>(find.byType(AndroidPlayerScene))
          .lyricsMode,
      isFalse,
    );
    expect(tester.getSize(cover).width, greaterThan(200));
    expect(session.audio.seeks, isEmpty);
    expect(session.playback.isPlaying, isTrue);
    await _unmount(tester);
  });

  testWidgets(
    'only lyrics card song title shrinks to 0.65 and artist stays readable',
    (tester) async {
      await _open(tester, lyrics: false);
      final title = _inPlayer(find.byType(MarqueeText));
      final artworkSize = tester.widget<MarqueeText>(title).style!.fontSize!;
      final artistSize = tester
          .widget<Text>(_inPlayer(find.text(_track.artistNames)))
          .style!
          .fontSize;

      await tester.tap(_inPlayer(find.byTooltip('歌词')));
      await _frames(tester);

      expect(
        tester.widget<MarqueeText>(title).style!.fontSize,
        closeTo(artworkSize * 0.65, 0.01),
      );
      expect(
        tester
            .widget<Text>(_inPlayer(find.text(_track.artistNames)))
            .style!
            .fontSize,
        artistSize,
      );
      await tester.tap(_inPlayer(find.byTooltip('歌词')));
      await _frames(tester);
      expect(tester.widget<MarqueeText>(title).style!.fontSize, artworkSize);
      await _unmount(tester);
    },
  );

  for (final text in [_track.name, _track.artistNames]) {
    testWidgets(
      'lyrics card text $text opens destinations rather than seeking or navigating',
      (tester) async {
        final session = await _open(tester);
        await tester.tap(_inPlayer(find.text(text)).first);
        await _frames(tester);

        expect(find.text('前往专辑'), findsOneWidget);
        expect(find.text('前往艺人'), findsNWidgets(2));
        expect(find.text(_album.name), findsOneWidget);
        expect(find.text(_artist.name), findsOneWidget);
        expect(find.text(_guest.name), findsOneWidget);
        expect(find.byType(ArtistDetailScreen), findsNothing);
        expect(find.byType(FullPlayerSheet), findsOneWidget);
        expect(session.audio.seeks, isEmpty);
        expect(session.playback.position, const Duration(seconds: 30));
        await _unmount(tester);
      },
    );
  }

  for (final destination in ['album', 'artist', 'guest']) {
    testWidgets(
      'lyrics card destination $destination opens visibly and preserves playback/history',
      (tester) async {
        final session = await _open(tester);
        await tester.tap(_inPlayer(find.text(_track.name)).first);
        await _frames(tester);
        await tester.tap(
          find.text(switch (destination) {
            'album' => _album.name,
            'artist' => _artist.name,
            _ => _guest.name,
          }),
        );
        await _frames(tester);

        expect(find.byType(FullPlayerSheet, skipOffstage: false), findsNothing);
        if (destination == 'album') {
          expect(
            tester
                .widget<AlbumDetailScreen>(find.byType(AlbumDetailScreen))
                .album
                .id,
            _album.id,
          );
        } else {
          expect(
            tester
                .widget<ArtistDetailScreen>(find.byType(ArtistDetailScreen))
                .artist
                .id,
            destination == 'artist' ? _artist.id : _guest.id,
          );
        }
        expect(session.playback.currentTrack?.id, _track.id);
        expect(session.playback.isPlaying, isTrue);
        expect(session.audio.seeks, isEmpty);
        AppRoutes.contentNavigator!()!.pop();
        await _frames(tester);
        expect(
          tester
              .widget<AlbumDetailScreen>(find.byType(AlbumDetailScreen))
              .album
              .id,
          _previousAlbum.id,
        );
        expect(tester.takeException(), isNull);
        await _unmount(tester);
      },
    );
  }

  testWidgets('lyrics card like button remains independent', (tester) async {
    final session = await _open(tester);
    await tester.tap(_inPlayer(find.byType(LikeButton)));
    await _frames(tester);

    final library = tester
        .element(find.byType(FullPlayerSheet))
        .read<LibraryProvider>();
    expect(library.isLiked(_track.id), isTrue);
    expect(find.text('前往专辑'), findsNothing);
    expect(session.audio.seeks, isEmpty);
    await _unmount(tester);
  });

  testWidgets(
    'whole card text button including blank space has a 48dp target',
    (tester) async {
      final session = await _open(tester);
      final header = find.byKey(const ValueKey('player-card-title'));
      final rect = tester.getRect(header);
      expect(rect.height, greaterThanOrEqualTo(48));

      await tester.tapAt(Offset(rect.right - 2, rect.bottom - 2));
      await _frames(tester);

      expect(find.text('前往专辑'), findsOneWidget);
      expect(session.audio.seeks, isEmpty);
      await _unmount(tester);
    },
  );

  testWidgets('rapid header and destination taps do not duplicate routes', (
    tester,
  ) async {
    await _open(tester);
    final header = find.byKey(const ValueKey('player-card-title'));
    // Activate twice before the first modal can build its input barrier.
    await tester.tap(header);
    await tester.tap(header);
    await _frames(tester);
    expect(find.text('前往专辑'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('前往专辑'), matching: find.byType(ListTile)),
    );
    tile.onTap!();
    tile.onTap!();
    await _frames(tester);
    AppRoutes.contentNavigator!()!.pop();
    await _frames(tester);
    expect(
      tester.widget<AlbumDetailScreen>(find.byType(AlbumDetailScreen)).album.id,
      _previousAlbum.id,
    );
    expect(find.byType(FullPlayerSheet, skipOffstage: false), findsNothing);
    await _unmount(tester);
  });

  testWidgets(
    'missing album and artist IDs show disabled destinations and placeholders',
    (tester) async {
      const track = SpotifyTrack(
        id: 'local',
        name: 'Local Song',
        artists: [SpotifyArtist(id: '', name: 'Unknown')],
      );
      final session = await _open(tester, track: track);
      await tester.tap(_inPlayer(find.text(track.name)).first);
      await _frames(tester);
      for (final label in ['前往专辑', '前往艺人']) {
        final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text(label), matching: find.byType(ListTile)),
        );
        expect(tile.enabled, isFalse);
        expect(tile.onTap, isNull);
      }
      expect(session.api.artistRequests, isEmpty);
      expect(find.byIcon(Icons.person_rounded), findsOneWidget);
      expect(session.audio.seeks, isEmpty);
      await _unmount(tester);
    },
  );

  testWidgets(
    'destinations show album artwork and available artist portrait without a metadata request',
    (tester) async {
      const portrait = 'https://example.invalid/artist.jpg';
      const cover = 'https://example.invalid/album.jpg';
      const artist = SpotifyArtist(
        id: 'portrayed',
        name: 'Portrayed Artist',
        images: [SpotifyImage(url: portrait)],
      );
      final track = _track.copyWith(
        artists: [artist],
        album: const SpotifyAlbum(
          id: 'art-album',
          name: 'Art Album',
          images: [SpotifyImage(url: cover)],
        ),
      );
      final session = await _open(tester, track: track);
      await tester.tap(_inPlayer(find.text(track.name)).first);
      await _frames(tester);
      final albumTile = find.ancestor(
        of: find.text('前往专辑'),
        matching: find.byType(ListTile),
      );
      final artistTile = find.ancestor(
        of: find.text('前往艺人'),
        matching: find.byType(ListTile),
      );
      expect(
        tester
            .widget<CoverImage>(
              find.descendant(of: albumTile, matching: find.byType(CoverImage)),
            )
            .url,
        cover,
      );
      final avatar = tester.widget<CoverImage>(
        find.descendant(of: artistTile, matching: find.byType(CoverImage)),
      );
      expect(avatar.url, portrait);
      expect(avatar.circular, isTrue);
      expect(session.api.artistRequests, isEmpty);
      await _unmount(tester);
    },
  );

  testWidgets(
    'missing artist portraits resolve once per distinct artist and late results are safe',
    (tester) async {
      final first = Completer<SpotifyArtist>();
      final second = Completer<SpotifyArtist>();
      final session = await _open(
        tester,
        track: _track.copyWith(artists: [_artist, _artist, _guest]),
        artistDetails: {_artist.id: first.future, _guest.id: second.future},
      );
      await tester.tap(_inPlayer(find.text(_track.name)).first);
      await _frames(tester);
      expect(find.text('前往艺人'), findsNWidgets(2));
      expect(session.api.artistRequests, [_artist.id, _guest.id]);
      first.complete(
        const SpotifyArtist(
          id: 'card-artist',
          name: 'Card Artist',
          images: [SpotifyImage(url: 'https://example.invalid/resolved.jpg')],
        ),
      );
      await _frames(tester);
      final artistTile = find.ancestor(
        of: find.text(_artist.name),
        matching: find.byType(ListTile),
      );
      expect(
        tester
            .widget<CoverImage>(
              find.descendant(
                of: artistTile,
                matching: find.byType(CoverImage),
              ),
            )
            .url,
        'https://example.invalid/resolved.jpg',
      );
      Navigator.of(
        tester.element(find.text('前往专辑')),
        rootNavigator: true,
      ).pop();
      await _frames(tester);
      second.completeError(StateError('offline'));
      await _frames(tester);
      expect(tester.takeException(), isNull);
      expect(session.audio.seeks, isEmpty);
      await _unmount(tester);
    },
  );

  testWidgets('destinations pause card auto-hide and dismissal re-arms it', (
    tester,
  ) async {
    await _open(tester);
    await tester.tap(_inPlayer(find.text(_track.name)).first);
    await _frames(tester);
    final header = find.byKey(const ValueKey('player-card-title'));
    final expandedTop = tester.getTopLeft(header).dy;
    expect(
      tester
          .widget<AndroidPlayerScene>(find.byType(AndroidPlayerScene))
          .interactionSuspended,
      isTrue,
    );
    await tester.pump(const Duration(seconds: 5));
    await _frames(tester);
    expect(tester.getTopLeft(header).dy, expandedTop);

    Navigator.of(tester.element(find.text('前往专辑')), rootNavigator: true).pop();
    await _frames(tester);
    expect(
      tester
          .widget<AndroidPlayerScene>(find.byType(AndroidPlayerScene))
          .interactionSuspended,
      isFalse,
    );
    expect(header.hitTestable(), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await _frames(tester);
    expect(header.hitTestable(), findsNothing);
    expect(_inPlayer(find.byTooltip('歌词')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    '320x568 with 2x text scrolls all artist destinations and cancels safely',
    (tester) async {
      final artists = List.generate(
        12,
        (index) => SpotifyArtist(
          id: 'small-screen-artist-$index',
          name: 'Collaborating Artist ${index + 1}',
        ),
      );
      final track = _track.copyWith(artists: artists);
      final session = await _open(tester, track: track);
      tester.view.physicalSize = const Size(320, 568);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _frames(tester);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byKey(const ValueKey('player-card-title')));
      await _frames(tester);
      final sheet = find.byType(PlayerDestinationsSheet);
      final scrollable = find.descendant(
        of: sheet,
        matching: find.byType(Scrollable),
      );
      final lastArtist = find.descendant(
        of: sheet,
        matching: find.text(artists.last.name),
      );
      expect(lastArtist.hitTestable(), findsNothing);
      await tester.scrollUntilVisible(lastArtist, 240, scrollable: scrollable);
      await _frames(tester);
      expect(
        tester.state<ScrollableState>(scrollable).position.pixels,
        greaterThan(0),
      );
      expect(lastArtist.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);

      Navigator.of(tester.element(sheet), rootNavigator: true).pop();
      await _frames(tester);
      expect(find.byType(FullPlayerSheet), findsOneWidget);
      expect(sheet, findsNothing);
      expect(session.playback.currentTrack?.id, track.id);
      expect(session.playback.isPlaying, isTrue);
      expect(session.playback.position, const Duration(seconds: 30));
      expect(session.audio.seeks, isEmpty);
      expect(tester.takeException(), isNull);
      // Menu responsiveness is separate from the existing player-close issue
      // when font scaling changes after its compact origin was captured.
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.view.physicalSize = const Size(390, 844);
      await _frames(tester);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );
}
