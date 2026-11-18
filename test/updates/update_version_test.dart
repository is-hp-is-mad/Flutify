import 'package:flutify_app/models/update_release.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  int cmp(String a, String b) =>
      UpdateVersion.parse(a)!.compareTo(UpdateVersion.parse(b)!).sign;

  test('两段式与三段式 tag 按同一规则排序', () {
    const ordered = [
      'v0.07',
      'v0.14-beta',
      'v0.14',
      'v0.15',
      'v0.16',
      'v0.16.1',
      'v0.17-rc1',
      'v0.17',
      'v1.0',
      'v1.0.1',
    ];
    for (var i = 0; i < ordered.length; i++) {
      for (var j = 0; j < ordered.length; j++) {
        expect(
          cmp(ordered[i], ordered[j]),
          (i - j).sign,
          reason: '${ordered[i]} vs ${ordered[j]}',
        );
      }
    }
  });

  test('v0.16 与 v0.16.0 相同', () {
    expect(cmp('v0.16', 'v0.16.0'), 0);
  });
}
