import 'dart:typed_data';

import '../aes.dart';

/// 音频解密器：按文件字节顺序原地处理数据块（可任意分块）。
abstract class AudioDecryptor {
  void process(Uint8List data);
}

/// 解密方式描述（纯数据，可以发送给后台解密 Isolate，在那边 [create] 出解密器）。
///
/// 扩展新的解密方法：新增一个子类，实现 [create] 返回对应的 [AudioDecryptor]，
/// 再让 TrackAudioLoader 在取得密钥后构造这个 Spec 即可；下载、续传、后台线程都不用改。
/// 注意子类只能包含可跨 Isolate 发送的字段（基本类型、TypedData、List / Map 等）。
abstract class DecryptSpec {
  const DecryptSpec();

  /// 从文件第 [offset] 字节开始解密（断点续传时 offset > 0）。
  AudioDecryptor create(int offset);
}

/// Spotify 音频文件当前的加密方式：AES-128-CTR，密钥来自 AP 音频密钥，IV 为协议常量。
class AesCtrDecryptSpec extends DecryptSpec {
  final Uint8List key;
  final Uint8List iv;

  const AesCtrDecryptSpec({required this.key, required this.iv});

  @override
  AudioDecryptor create(int offset) => _AesCtrDecryptor(AesCtr.atOffset(key, iv, offset));
}

class _AesCtrDecryptor implements AudioDecryptor {
  final AesCtr _ctr;

  _AesCtrDecryptor(this._ctr);

  @override
  void process(Uint8List data) => _ctr.process(data);
}

/// 不解密（数据本身是明文）：调试、或将来某些来源不需要解密时使用。
class PassthroughDecryptSpec extends DecryptSpec {
  const PassthroughDecryptSpec();

  @override
  AudioDecryptor create(int offset) => const _PassthroughDecryptor();
}

class _PassthroughDecryptor implements AudioDecryptor {
  const _PassthroughDecryptor();

  @override
  void process(Uint8List data) {}
}
