import '../../models/track_credits.dart';

/// `queryTrackCreditsGroupedModal` 响应 → [TrackCredits]。
///
/// 响应是扁平的「人 × 角色」列表（`creditsTrait.contributors.items`，每项含 roleGroup / role / name / uri），
/// 这里按 roleGroup 分组（保持首次出现的顺序），同组内同一人的多个角色合并（如「作曲者、作词者」）。
class CreditsParser {
  CreditsParser._();

  static TrackCredits? parse(Map<String, dynamic> data) {
    // PathfinderClient.query 已解包外层 data，直接传入内层字段；兼容保留外层 data 的调用。
    final track = data['trackUnion'] ?? (data['data'] as Map?)?['trackUnion'];
    if (track is! Map) return null;
    final trait = track['creditsTrait'];
    final items = _items(trait, 'contributors');

    // 分组名 → (人员键 → 合并中的人员)；LinkedHashMap 保序
    final groups = <String, Map<String, _PersonBuilder>>{};
    if (items is List) {
      for (final item in items.whereType<Map>()) {
        final name = (item['name'] as String? ?? '').trim();
        if (name.isEmpty) continue;
        final group = ((item['roleGroup'] as Map?)?['name'] as String? ?? '').trim();
        final role = (item['role'] as String? ?? '').trim();
        final uri = item['uri'] as String? ?? '';
        final artistId = uri.startsWith('spotify:artist:') ? uri.substring('spotify:artist:'.length) : '';

        final people = groups.putIfAbsent(group, () => {});
        final person = people.putIfAbsent(artistId.isNotEmpty ? artistId : name, () => _PersonBuilder(name, artistId));
        if (role.isNotEmpty && !person.roles.contains(role)) person.roles.add(role);
      }
    }

    final sourceItems = _items(trait, 'sources');
    return TrackCredits(
      trackName: track['name'] as String? ?? '',
      groups: [
        for (final entry in groups.entries)
          CreditGroup(name: entry.key, people: [for (final p in entry.value.values) p.build()]),
      ],
      sources: [
        if (sourceItems is List)
          for (final s in sourceItems.whereType<Map>())
            if ((s['name'] as String? ?? '').trim().isNotEmpty) (s['name'] as String).trim(),
      ],
    );
  }

  /// `creditsTrait.<field>.items`；结构不符时返回 null。
  static Object? _items(Object? trait, String field) {
    if (trait is! Map) return null;
    final section = trait[field];
    return section is Map ? section['items'] : null;
  }
}

class _PersonBuilder {
  final String name;
  final String artistId;
  final List<String> roles = [];

  _PersonBuilder(this.name, this.artistId);

  CreditPerson build() => CreditPerson(name: name, roles: List.unmodifiable(roles), artistId: artistId);
}
