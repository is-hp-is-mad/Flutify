import 'package:flutter_test/flutter_test.dart';

import '../../tool/player_lyrics_preview.dart';

void main() {
  test(
    'offline preview seek changes the clock that drives later ticks',
    () async {
      final audio = PlayerPreviewAudio();
      addTearDown(audio.dispose);
      final positions = <Duration>[];
      final subscription = audio.positionStream.listen(positions.add);
      addTearDown(subscription.cancel);
      await audio.play();
      audio.advance();
      expect(audio.position, const Duration(milliseconds: 250));
      await audio.seek(const Duration(seconds: 16));
      audio.advance();
      expect(positions.last, const Duration(milliseconds: 16250));
      await audio.pause();
      audio.advance();
      expect(audio.position, const Duration(milliseconds: 16250));
    },
  );

  test('offline preview loops through its intro and clamps seeks', () async {
    final audio = PlayerPreviewAudio();
    addTearDown(audio.dispose);
    await audio.play();
    await audio.seek(const Duration(milliseconds: 64750));
    audio.advance();
    expect(audio.position, Duration.zero);
    await audio.seek(const Duration(seconds: -1));
    expect(audio.position, Duration.zero);
    await audio.seek(const Duration(minutes: 2));
    expect(audio.position, audio.duration);
  });
}
