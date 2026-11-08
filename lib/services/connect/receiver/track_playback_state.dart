/// track-playback 协议（Web 播放器 / harmony SDK 同款）的状态机模型。
///
/// 服务端通过 `hm://track-playback/v1/command` 的 `replace_state` 下发整份状态机：
/// - [TpStateMachine.tracks]：前后若干首曲目（元数据 + 音频文件 id）；
/// - [TpStateMachine.states]：若干「播放状态」，每个指向一首曲目，并带跳转表
///   （下一首 / 上一首 / 播完自动进入 分别跳到哪个状态）；
/// - [TpStateRef]：当前处于哪个状态、是否暂停。
/// 播放端按跳转表在本地切换状态，并用 `PUT …/devices/{id}/state` 汇报。
library;

/// 指向状态机里某个状态的引用（命令里的 `state_ref` / 跳转表里的目标）。
class TpStateRef {
  final int stateIndex;
  final bool paused;

  const TpStateRef(this.stateIndex, {required this.paused});

  static TpStateRef? fromJson(Object? json) {
    if (json is! Map) return null;
    final index = json['state_index'];
    if (index is! int) return null;
    return TpStateRef(index, paused: json['paused'] == true);
  }
}

/// 状态机里的一首曲目。
class TpTrack {
  final String uri;
  final String name;
  final String albumName;
  final String albumUri;
  final List<({String name, String uri})> artists;
  final int durationMs;
  final bool explicit;
  final bool isAdvertisement;

  /// 封面，按尺寸从大到小。
  final List<String> imageUrls;

  const TpTrack({
    required this.uri,
    required this.name,
    this.albumName = '',
    this.albumUri = '',
    this.artists = const [],
    this.durationMs = 0,
    this.explicit = false,
    this.isAdvertisement = false,
    this.imageUrls = const [],
  });

  factory TpTrack.fromJson(Map<String, dynamic> json) {
    final meta =
        (json['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final images = [
      for (final i in (meta['images'] as List? ?? const []))
        if (i is Map && i['url'] is String)
          (url: i['url'] as String, w: (i['width'] as num?)?.toInt() ?? 0),
    ]..sort((a, b) => b.w.compareTo(a.w));
    return TpTrack(
      uri: meta['uri'] as String? ?? '',
      name: meta['name'] as String? ?? '',
      albumName: meta['group_name'] as String? ?? '',
      albumUri: meta['group_uri'] as String? ?? '',
      artists: [
        for (final a in (meta['authors'] as List? ?? const []))
          if (a is Map)
            (name: a['name'] as String? ?? '', uri: a['uri'] as String? ?? ''),
      ],
      durationMs: (meta['duration'] as num?)?.toInt() ?? 0,
      explicit: meta['is_explicit'] == true,
      isAdvertisement:
          meta['is_advertisement'] == true ||
          meta['is_advertisement'] == 'true' ||
          (meta['uri'] as String? ?? '').startsWith('spotify:ad:'),
      imageUrls: [for (final i in images) i.url],
    );
  }
}

/// 状态机里的一个状态。
class TpState {
  final String stateId;
  final int track;
  final bool disallowSeeking;
  final TpStateRef? skipNext;
  final TpStateRef? skipPrev;
  final TpStateRef? advance;

  const TpState({
    required this.stateId,
    required this.track,
    this.disallowSeeking = false,
    this.skipNext,
    this.skipPrev,
    this.advance,
  });

  factory TpState.fromJson(Map<String, dynamic> json) {
    final t = (json['transitions'] as Map?) ?? const {};
    return TpState(
      stateId: json['state_id'] as String? ?? '',
      track: (json['track'] as num?)?.toInt() ?? 0,
      disallowSeeking: json['disallow_seeking'] == true,
      skipNext: TpStateRef.fromJson(t['skip_next']),
      skipPrev: TpStateRef.fromJson(t['skip_prev']),
      advance: TpStateRef.fromJson(t['advance']),
    );
  }
}

/// 播放选项（状态机 `attributes.options`）：随机 / 列表循环 / 单曲循环。
class TpOptions {
  // null 表示服务端未下发该项，不能当作关闭覆盖本机设置。
  final bool? shuffle;
  final bool? repeatContext;
  final bool? repeatTrack;

  const TpOptions({this.shuffle, this.repeatContext, this.repeatTrack});

  factory TpOptions.fromJson(Object? json) {
    if (json is! Map) return const TpOptions();
    return TpOptions(
      shuffle: json['shuffling_context'] as bool?,
      repeatContext: json['repeating_context'] as bool?,
      repeatTrack: json['repeating_track'] as bool?,
    );
  }
}

class TpStateMachine {
  final String id;
  final List<TpTrack> tracks;
  final List<TpState> states;
  final TpOptions options;

  const TpStateMachine({
    required this.id,
    required this.tracks,
    required this.states,
    this.options = const TpOptions(),
  });

  static TpStateMachine? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['state_machine_id'];
    if (id is! String || id.isEmpty) return null;
    return TpStateMachine(
      id: id,
      options: TpOptions.fromJson((json['attributes'] as Map?)?['options']),
      tracks: [
        for (final t in (json['tracks'] as List? ?? const []))
          if (t is Map) TpTrack.fromJson(t.cast<String, dynamic>()),
      ],
      states: [
        for (final s in (json['states'] as List? ?? const []))
          if (s is Map) TpState.fromJson(s.cast<String, dynamic>()),
      ],
    );
  }

  TpState? state(int index) =>
      index >= 0 && index < states.length ? states[index] : null;

  TpTrack? trackOf(TpState state) =>
      state.track >= 0 && state.track < tracks.length
      ? tracks[state.track]
      : null;

  /// 从 [index] 起沿「播完自动进入」走出的播放顺序（含自身，最多 [limit] 个，遇环停止）。
  List<int> advanceChain(int index, {int limit = 50}) {
    final out = <int>[];
    var cur = state(index);
    var i = index;
    while (cur != null && out.length < limit && !out.contains(i)) {
      out.add(i);
      // 单曲循环的 advance 指回自身，但手动下一首仍需展示后续曲目。
      final next = cur.advance == null || cur.advance?.stateIndex == i
          ? cur.skipNext
          : cur.advance;
      if (next == null) break;
      i = next.stateIndex;
      cur = state(i);
    }
    return out;
  }

  /// 广告不进入播放器或展示队列，仍保留原状态下标用于服务端同步。
  List<int> playableChain(int index) => [
    for (final i in advanceChain(index))
      if (trackOf(states[i]) case final track?)
        if (!track.isAdvertisement) i,
  ];

  /// 只越过广告，不能跨过正常歌曲去匹配任意队列项。
  int? playableState(int index, {bool backwards = false}) {
    final visited = <int>{};
    var i = index;
    while (visited.add(i)) {
      final current = state(i);
      if (current == null) return null;
      final track = trackOf(current);
      if (track == null) return null;
      if (!track.isAdvertisement) return i;
      final next = backwards
          ? current.skipPrev
          : current.advance == null || current.advance?.stateIndex == i
          ? current.skipNext
          : current.advance;
      if (next == null) return null;
      i = next.stateIndex;
    }
    return null;
  }
}

/// `replace_state` 命令。
class TpReplaceState {
  final TpStateMachine machine;
  final TpStateRef ref;

  /// 起播位置（毫秒）；为空表示从头。
  final int? seekTo;

  const TpReplaceState(this.machine, this.ref, this.seekTo);

  static TpReplaceState? fromJson(Map<String, dynamic> json) {
    final machine = TpStateMachine.fromJson(json['state_machine']);
    final ref = TpStateRef.fromJson(json['state_ref']);
    if (machine == null || ref == null || machine.state(ref.stateIndex) == null)
      return null;
    return TpReplaceState(machine, ref, (json['seek_to'] as num?)?.toInt());
  }
}
