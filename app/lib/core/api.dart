import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import 'home_connection.dart';

/// Where home is and how to sign requests, or null before connecting.
@immutable
class HomeConfig {
  const HomeConfig(this.address, this.key);
  final Uri address;
  final String? key;

  Map<String, String> get authHeaders =>
      key == null ? const {} : {'Authorization': 'Bearer $key'};

  @override
  bool operator ==(Object other) =>
      other is HomeConfig && other.address == address && other.key == key;

  @override
  int get hashCode => Object.hash(address, key);
}

final homeConfigProvider = Provider<HomeConfig?>((ref) {
  final store = ref.watch(homeAddressStoreProvider);
  void changed() => ref.invalidateSelf();
  store.addListener(changed);
  ref.onDispose(() => store.removeListener(changed));
  final address = store.address;
  return address == null ? null : HomeConfig(address, store.key);
});

Dio dioForHome(HomeConfig config) => Dio(
  BaseOptions(
    baseUrl: config.address.toString(),
    connectTimeout: const Duration(seconds: 8),
    // Lossy streams are made on first request, which can take a few seconds.
    receiveTimeout: const Duration(seconds: 60),
    headers: {'Accept': 'application/json', ...config.authHeaders},
  ),
);

/// The API client for the connected home. Replaced in tests.
final hiveApiProvider = Provider<HiveApi>((ref) {
  final config = ref.watch(homeConfigProvider);
  if (config == null) {
    throw StateError('Not connected to a home yet');
  }
  return HiveApi(dioForHome(config));
});

/// Cover art at one of the server's sizes, sent with this device's key.
ImageProvider? artworkImage(
  WidgetRef ref,
  String? artworkId, {
  int size = 300,
}) {
  if (artworkId == null) return null;
  final config = ref.watch(homeConfigProvider);
  if (config == null) return null;
  final snapped = const [
    96,
    192,
    300,
    600,
    1200,
  ].firstWhere((s) => s >= size, orElse: () => 1200);
  final url = config.address.resolve(
    '/api/v1/media/artwork/${Uri.encodeComponent(artworkId)}?size=$snapped',
  );
  return NetworkImage(url.toString(), headers: config.authHeaders);
}

/// Plain words for any failed call; the server's own detail when it sent one.
String describeError(Object error) {
  if (error is HiveApiException) {
    if (error.unreachable) {
      return "Can't reach home. The music PC may be asleep, or the private connection is off.";
    }
    if (error.status == 401) {
      return "Home didn't accept this device's key. Copy it again from Hive Admin → Overview.";
    }
    return error.problem?.detail ??
        error.problem?.title ??
        'Something went wrong (${error.status}).';
  }
  return 'Something went wrong.';
}
