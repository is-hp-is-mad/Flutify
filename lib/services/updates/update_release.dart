/// 更新通道。排在后面的通道也会收到前面通道的版本：
/// 正式版用户只收正式版，测试版用户收测试版和正式版，自测版用户全收。
enum UpdateChannel { release, beta, selfTest }

/// The old v0.01 … v0.06 tags represent app versions 0.0.1 … 0.0.6.
/// Keep that convention for two-component 0.xx tags; new releases can use SemVer.
class UpdateVersion implements Comparable<UpdateVersion> {
  final List<int> numbers;
  final String? stage;
  final int stageNumber;
  const UpdateVersion(this.numbers, this.stage, this.stageNumber);

  /// 实质版本号：CI 每编译一次加一，三个通道共用一个序列，写在标签第三段
  /// （v0.18.151 / v0.18.140-beta / v0.18.135-selftest）。旧的两段式标签为 0。
  int get build => numbers[2];

  UpdateChannel get channel => switch (stage) {
    null => UpdateChannel.release,
    'selftest' => UpdateChannel.selfTest,
    _ => UpdateChannel.beta,
  };

  /// 能否从 [current] 更新到这个版本。只升不降：基础版本（前两段）不能更低，
  /// 实质版本号必须更高；两边都没有实质版本号的旧标签沿用原来的比较。
  bool isUpgradeFrom(UpdateVersion current) {
    for (var i = 0; i < 2; i++) {
      if (numbers[i] < current.numbers[i]) return false;
    }
    if (build != current.build) return build > current.build;
    return compareTo(current) > 0;
  }

  static UpdateVersion? parse(String tag) {
    final match = RegExp(
      r'^v?(\d+)\.(\d+)(?:\.(\d+))?(?:-(alpha|beta|rc|selftest)(?:[.-]?(\d+))?)?(?:\+[\w.-]+)?$',
    ).firstMatch(tag);
    if (match == null) return null;
    // v0.15 = 0.15.0、v0.16.1 = 0.16.1：两段式与三段式按同一规则比较，
    // 否则 v0.17 会被当成比 v0.16.1 旧
    return UpdateVersion(
      [
        int.parse(match[1]!),
        int.parse(match[2]!),
        int.parse(match[3] ?? '0'),
      ],
      match[4],
      int.parse(match[5] ?? '0'),
    );
  }

  @override
  int compareTo(UpdateVersion other) {
    for (var i = 0; i < 3; i++) {
      final order = numbers[i].compareTo(other.numbers[i]);
      if (order != 0) return order;
    }
    const stages = {'selftest': -1, 'alpha': 0, 'beta': 1, 'rc': 2, null: 3};
    final order = stages[stage]!.compareTo(stages[other.stage]!);
    return order != 0 ? order : stageNumber.compareTo(other.stageNumber);
  }
}

enum UpdateMode { manual, automatic, disabled }

enum UpdatePlatform { windowsPortable, windowsInstaller, android, unsupported }

class UpdateTarget {
  final UpdatePlatform platform;
  final String architecture;
  const UpdateTarget(this.platform, this.architecture);

  List<String> get suffixes => switch (platform) {
    UpdatePlatform.windowsPortable => ['windows-$architecture.zip'],
    UpdatePlatform.windowsInstaller => ['windows-$architecture-setup.exe'],
    UpdatePlatform.android => [
      'android-$architecture.apk',
      'android-universal.apk',
    ],
    UpdatePlatform.unsupported => [],
  };
}

class UpdateAsset {
  final String name;
  final Uri url;
  final int size;
  const UpdateAsset(this.name, this.url, this.size);

  static UpdateAsset? fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final size = json['size'];
    final url = Uri.tryParse(json['browser_download_url'] as String? ?? '');
    if (name is! String || size is! int || size <= 0 || url == null ||
        url.scheme != 'https' || url.host != 'github.com' ||
        !url.path.startsWith('/is-hp-is-mad/Flutify/releases/download/') ||
        !RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(name)) {
      return null;
    }
    return UpdateAsset(name, url, size);
  }
}

class UpdateRelease {
  final String tag;
  final String notes;
  final Uri page;
  final UpdateVersion version;
  final List<UpdateAsset> assets;
  const UpdateRelease({
    required this.tag,
    required this.notes,
    required this.page,
    required this.version,
    required this.assets,
  });

  static UpdateRelease? fromJson(Map<String, dynamic> json) {
    if (json['draft'] == true) return null;
    final tag = json['tag_name'] as String? ?? '';
    final version = UpdateVersion.parse(tag);
    if (version == null) return null;
    return UpdateRelease(
      tag: tag,
      notes: json['body'] as String? ?? '',
      page: Uri.https('github.com', '/is-hp-is-mad/Flutify/releases/tag/$tag'),
      version: version,
      assets: [
        for (final item in json['assets'] as List? ?? [])
          if (item is Map<String, dynamic>)
            ?UpdateAsset.fromJson(item),
      ],
    );
  }

  UpdateAsset? assetFor(UpdateTarget target) {
    for (final suffix in target.suffixes) {
      for (final asset in assets) {
        if (asset.name == 'Flutify-$tag-$suffix') return asset;
      }
    }
    return null;
  }

  UpdateAsset? get checksums {
    for (final asset in assets) {
      if (asset.name == 'SHA256SUMS.txt') return asset;
    }
    return null;
  }
}
