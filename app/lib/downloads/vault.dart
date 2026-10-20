import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../auth/device_auth.dart';
import '../auth/secret_store.dart';

/// Where downloaded songs are kept on this device, locked with a key that
/// never leaves it. Copying the files off the device gives nothing playable,
/// and signing the device out deletes the key along with the files.
abstract class DownloadVault {
  Future<String?> readIndex();
  Future<void> writeIndex(String json);

  /// Keeps a song, locking it as it arrives (nothing is written unlocked).
  /// Returns the number of bytes kept.
  Future<int> store(
    String trackId,
    Stream<List<int>> bytes, {
    void Function(int received)? progress,
  });

  /// The song's bytes from [start] up to [end] (exclusive), unlocked.
  Stream<List<int>> open(String trackId, int start, [int? end]);

  /// The song's size, unlocked; null when it isn't here.
  Future<int?> sizeOf(String trackId);
  Future<void> remove(String trackId);

  Future<void> storeArt(String artworkId, List<int> bytes);

  /// A cover kept for playing with home off, if there is one.
  Future<String?> artPath(String artworkId);
  Future<void> removeArt(String artworkId);

  /// Everything gone, the key too.
  Future<void> wipe();
}

/// Files in the app's own storage, each locked with ChaCha20 under a key kept
/// in the platform's secure storage. ChaCha20 is a stream cipher, so any part
/// of a song can be unlocked on its own: seeking works without unlocking
/// everything before it.
class FileVault implements DownloadVault {
  FileVault(this._dir, this._secrets);

  final Future<Directory> Function() _dir;
  final SecretStore _secrets;
  static const _keyName = 'downloads.key';
  static const _nonceLength = 12;
  static const _chunk = 64 * 1024;
  final _cipher = Chacha20(macAlgorithm: MacAlgorithm.empty);
  SecretKey? _key;

  Future<SecretKey> _secret() async {
    if (_key != null) return _key!;
    var raw = await _secrets.read(_keyName);
    if (raw == null) {
      final r = Random.secure();
      raw = base64Url.encode(List.generate(32, (_) => r.nextInt(256)));
      await _secrets.write(_keyName, raw);
    }
    return _key = SecretKey(base64Url.decode(raw));
  }

  Future<File> _file(String name) async {
    final dir = await _dir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$name');
  }

  String _songName(String id) =>
      '${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.hive';
  String _artName(String id) =>
      'art-${base64Url.encode(utf8.encode(id)).replaceAll('=', '')}.jpg';

  @override
  Future<String?> readIndex() async {
    final f = await _file('index.json');
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> writeIndex(String json) async {
    final f = await _file('index.json');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<int> store(
    String trackId,
    Stream<List<int>> bytes, {
    void Function(int received)? progress,
  }) async {
    final key = await _secret();
    final nonce = _cipher.newNonce();
    final f = await _file(_songName(trackId));
    final part = File('${f.path}.part');
    final sink = part.openWrite();
    var offset = 0;
    final pending = BytesBuilder(copy: false);
    // The key stream can start anywhere, so pieces needn't line up with blocks.
    Future<void> flush() async {
      if (pending.isEmpty) return;
      final data = pending.takeBytes();
      final box = await _cipher.encrypt(
        data,
        secretKey: key,
        nonce: nonce,
        keyStreamIndex: offset,
      );
      sink.add(box.cipherText);
      offset += data.length;
    }

    try {
      sink.add(nonce);
      await for (final b in bytes) {
        pending.add(b);
        if (pending.length >= _chunk) await flush();
        progress?.call(offset + pending.length);
      }
      await flush();
      await sink.flush();
      await sink.close();
      await part.rename(f.path);
      return offset;
    } catch (_) {
      await sink.close().catchError((_) {});
      if (await part.exists()) await part.delete();
      rethrow;
    }
  }

  @override
  Stream<List<int>> open(String trackId, int start, [int? end]) async* {
    final key = await _secret();
    final f = await _file(_songName(trackId));
    final raf = await f.open();
    try {
      final nonce = await raf.read(_nonceLength);
      final size = await raf.length() - _nonceLength;
      final stop = min(end ?? size, size);
      var pos = start;
      await raf.setPosition(_nonceLength + pos);
      while (pos < stop) {
        final n = min(_chunk, stop - pos);
        final data = await raf.read(n);
        if (data.isEmpty) break;
        yield await _cipher.decrypt(
          SecretBox(data, nonce: nonce, mac: Mac.empty),
          secretKey: key,
          keyStreamIndex: pos,
        );
        pos += data.length;
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<int?> sizeOf(String trackId) async {
    final f = await _file(_songName(trackId));
    if (!await f.exists()) return null;
    return await f.length() - _nonceLength;
  }

  @override
  Future<void> remove(String trackId) async {
    final f = await _file(_songName(trackId));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> storeArt(String artworkId, List<int> bytes) async {
    final f = await _file(_artName(artworkId));
    await f.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<String?> artPath(String artworkId) async {
    final f = await _file(_artName(artworkId));
    return await f.exists() ? f.path : null;
  }

  @override
  Future<void> removeArt(String artworkId) async {
    final f = await _file(_artName(artworkId));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> wipe() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
    await _secrets.delete(_keyName);
    _key = null;
  }
}

/// Kept in memory, unlocked: for tests.
class MemoryVault implements DownloadVault {
  String? index;
  final songs = <String, Uint8List>{};
  final art = <String, List<int>>{};

  @override
  Future<String?> readIndex() async => index;
  @override
  Future<void> writeIndex(String json) async => index = json;

  @override
  Future<int> store(
    String trackId,
    Stream<List<int>> bytes, {
    void Function(int received)? progress,
  }) async {
    final b = BytesBuilder();
    await for (final chunk in bytes) {
      b.add(chunk);
      progress?.call(b.length);
    }
    songs[trackId] = b.takeBytes();
    return songs[trackId]!.length;
  }

  @override
  Stream<List<int>> open(String trackId, int start, [int? end]) async* {
    final s = songs[trackId]!;
    yield Uint8List.sublistView(s, start, min(end ?? s.length, s.length));
  }

  @override
  Future<int?> sizeOf(String trackId) async => songs[trackId]?.length;
  @override
  Future<void> remove(String trackId) async => songs.remove(trackId);
  @override
  Future<void> storeArt(String artworkId, List<int> bytes) async =>
      art[artworkId] = bytes;
  @override
  Future<String?> artPath(String artworkId) async => null;
  @override
  Future<void> removeArt(String artworkId) async => art.remove(artworkId);
  @override
  Future<void> wipe() async {
    index = null;
    songs.clear();
    art.clear();
  }
}

final downloadVaultProvider = Provider<DownloadVault>((ref) {
  final secrets = ref.watch(secretStoreProvider);
  return FileVault(() async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/downloads');
  }, secrets);
});

/// Covers kept with downloads (artwork id → file), so art shows with home off.
class DownloadedArt extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};
  void set(Map<String, String> paths) => state = paths;
}

final downloadedArtProvider =
    NotifierProvider<DownloadedArt, Map<String, String>>(DownloadedArt.new);
