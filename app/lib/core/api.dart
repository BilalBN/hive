import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/hive_api.g.dart';
import '../auth/device_auth.dart';
import 'home_connection.dart';

/// Where home is and, for homes still on M1's development key, that key.
/// Joined devices sign requests with their own tokens instead (see
/// [DeviceAuth]); or null before connecting.
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

Dio dioForHome(HomeConfig config, {DeviceAuth? auth}) {
  final dio = Dio(
    BaseOptions(
      baseUrl: config.address.toString(),
      connectTimeout: const Duration(seconds: 8),
      // Lossy streams are made on first request, which can take a few seconds.
      receiveTimeout: const Duration(seconds: 60),
      headers: {'Accept': 'application/json', ...config.authHeaders},
    ),
  );
  if (auth != null) dio.interceptors.add(DeviceTokenInterceptor(auth, dio));
  return dio;
}

/// Signs each call with this device's access token, and when home says the
/// token is no good, refreshes it once and tries the call again.
class DeviceTokenInterceptor extends Interceptor {
  DeviceTokenInterceptor(this.auth, this.dio);
  final DeviceAuth auth;
  final Dio dio;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (auth.signedIn) {
      try {
        final token = await auth.accessToken();
        if (token != null) options.headers['Authorization'] = 'Bearer $token';
      } catch (_) {
        // Home unreachable: the call will say so itself.
      }
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        !auth.signedIn ||
        options.extra['hive.retried'] == true) {
      return handler.next(err);
    }
    final body = err.response?.data;
    final problem = body is Map
        ? Problem.fromJson(body.cast<String, dynamic>())
        : null;
    if (!await auth.recoverFrom(HiveApiException(401, problem))) {
      return handler.next(err);
    }
    options.extra['hive.retried'] = true;
    options.headers['Authorization'] = 'Bearer ${auth.currentAccessToken}';
    try {
      handler.resolve(await dio.fetch<dynamic>(options));
    } on DioException catch (e) {
      handler.next(e);
    }
  }
}

/// The API client for the connected home. Replaced in tests.
final hiveApiProvider = Provider<HiveApi>((ref) {
  final config = ref.watch(homeConfigProvider);
  if (config == null) {
    throw StateError('Not connected to a home yet');
  }
  return HiveApi(dioForHome(config, auth: ref.watch(deviceAuthProvider)));
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
  final auth = ref.watch(deviceAuthProvider);
  ref.watch(accessTokenProvider);
  final headers = auth.signedIn ? auth.headers : config.authHeaders;
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
  return NetworkImage(url.toString(), headers: headers);
}

/// Plain words for any failed call; the server's own detail when it sent one.
String describeError(Object error) {
  if (error is HiveApiException) {
    if (error.unreachable) {
      return "Can't reach home. The music PC may be asleep, or the private connection is off.";
    }
    if (error.status == 401) {
      return error.problem?.detail ??
          "Home didn't let this device in. Join again from Settings.";
    }
    return error.problem?.detail ??
        error.problem?.title ??
        'Something went wrong (${error.status}).';
  }
  return 'Something went wrong.';
}
