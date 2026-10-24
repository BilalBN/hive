import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:unifiedpush/unifiedpush.dart';

import '../api/hive_api.g.dart';
import '../core/api.dart';
import '../core/home_connection.dart';
import '../sync/continuity.dart';

/// M6: notifications, with no personal details in them. While Hive is open
/// they arrive over the sync link and show inside the app; while it's
/// closed, Android phones get them through UnifiedPush (a distributor app
/// such as ntfy) and iPhones, iPads and Macs through Apple's push service.

/// A notification that arrived while Hive is open; the shell shows it.
final noticeProvider = NotifierProvider<NoticeNotifier, NoticeReceived?>(
  NoticeNotifier.new,
);

class NoticeNotifier extends Notifier<NoticeReceived?> {
  @override
  NoticeReceived? build() => null;
  void show(NoticeReceived n) => state = n;
}

/// How this device takes notifications while Hive is closed.
enum ClosedDelivery {
  /// Not possible here (Windows, or no way to reach this device).
  none,

  /// Android: a UnifiedPush distributor app is needed first.
  needsDistributor,

  /// Off on this device.
  off,

  /// On.
  on,
}

/// While Hive is open but out of sight (the Mac's menu bar, Windows' tray,
/// another app in front): show a notice the system way.
Future<void> showNoticeIfHidden(Ref ref, NoticeReceived n) async {
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
    return;
  }
  final d = ref.read(pushDeviceProvider);
  if (d.android || d.apple) return; // the push service shows those
  try {
    await d.showLocal(n.title, n.body);
  } catch (_) {}
}

/// Talks to the device about notifications. Replaced in tests.
abstract class PushDevice {
  bool get android;
  bool get apple;

  /// Android: hear UnifiedPush's new addresses and messages.
  Future<void> listen({
    required void Function(String url, String? pubKey, String? auth) onEndpoint,
    required void Function(Map<String, dynamic> message) onMessage,
  });
  Future<bool> hasDistributor();
  Future<void> registerUnifiedPush(String vapid);
  Future<void> unregisterUnifiedPush();

  /// Apple: ask permission and register; the device token (hex), or null.
  Future<String?> registerApple();
  Future<void> showLocal(String title, String body);
}

class RealPushDevice implements PushDevice {
  static const _apple = MethodChannel('hive/push');
  final _local = FlutterLocalNotificationsPlugin();
  bool _localReady = false;

  @override
  bool get android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// iPhones and iPads. (Macs keep Hive running in the menu bar, so they
  /// hear notifications over the sync link and show them as local ones.)
  @override
  bool get apple => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  @override
  Future<void> listen({
    required void Function(String url, String? pubKey, String? auth) onEndpoint,
    required void Function(Map<String, dynamic> message) onMessage,
  }) async {
    await UnifiedPush.initialize(
      onNewEndpoint: (e, _) =>
          onEndpoint(e.url, e.pubKeySet?.pubKey, e.pubKeySet?.auth),
      onMessage: (m, _) {
        if (!m.decrypted) return;
        try {
          onMessage(jsonDecode(utf8.decode(m.content)) as Map<String, dynamic>);
        } catch (_) {}
      },
    );
  }

  @override
  Future<bool> hasDistributor() async {
    if (!android) return false;
    return UnifiedPush.tryUseCurrentOrDefaultDistributor();
  }

  @override
  Future<void> registerUnifiedPush(String vapid) =>
      UnifiedPush.register(instance: 'hive', vapid: vapid);

  @override
  Future<void> unregisterUnifiedPush() => UnifiedPush.unregister('hive');

  @override
  Future<String?> registerApple() async {
    try {
      return await _apple.invokeMethod<String>('register');
    } on PlatformException {
      return null; // not allowed, or the build can't take Apple push yet
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> showLocal(String title, String body) async {
    if (!_localReady) {
      await _local.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          macOS: DarwinInitializationSettings(),
          windows: WindowsInitializationSettings(
            appName: 'Hive',
            appUserModelId: 'dev.hivemusic.hive',
            guid: '6f1c2a4e-8b3d-4e57-9a10-2c7d5e8f4b61',
          ),
        ),
      );
      await _local
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      _localReady = true;
    }
    await _local.show(
      id: DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'dev.hivemusic.hive.notices',
          'From home',
          channelDescription: 'New music, songs you asked for, and things for whoever runs Hive.',
        ),
      ),
    );
  }
}

final pushDeviceProvider = Provider<PushDevice>((ref) => RealPushDevice());

@immutable
class PushState {
  const PushState({this.settings, this.closed = ClosedDelivery.none});
  final PushSettings? settings;
  final ClosedDelivery closed;
}

class PushController extends Notifier<PushState> {
  static const _closedKey = 'push.whenClosed';
  bool _started = false;

  PushDevice get _device => ref.read(pushDeviceProvider);

  @override
  PushState build() {
    ref.listen(homeStatusProvider, (_, s) {
      if (s is HomeConnected) unawaited(refresh());
    });
    if (ref.read(homeStatusProvider) is HomeConnected) {
      Future.microtask(refresh);
    }
    return const PushState();
  }

  bool get _wantClosed =>
      ref.read(sharedPreferencesProvider).getBool(_closedKey) ?? true;

  Future<void> refresh() async {
    try {
      final settings = await ref.read(hiveApiProvider).getPushSettings();
      state = PushState(settings: settings, closed: state.closed);
      await _startClosed(settings);
    } catch (_) {
      // Tried again when home is back.
    }
  }

  Future<void> _startClosed(PushSettings settings) async {
    final d = _device;
    if (d.android) {
      if (!_started) {
        _started = true;
        await d.listen(
          onEndpoint: (url, key, auth) =>
              unawaited(saveEndpoint(url, key, auth).catchError((_) {})),
          onMessage: (n) {
            // Open: it shows inside Hive already (over the sync link).
            if (WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed) {
              return;
            }
            unawaited(
              d.showLocal('${n['title'] ?? 'Hive'}', '${n['body'] ?? ''}'),
            );
          },
        );
      }
      if (!await d.hasDistributor()) {
        state = PushState(
          settings: settings,
          closed: ClosedDelivery.needsDistributor,
        );
        return;
      }
      if (_wantClosed) {
        await d.registerUnifiedPush(settings.webPushKey);
      }
    } else if (d.apple && settings.apns) {
      if (_wantClosed) {
        final token = await d.registerApple();
        if (token != null) {
          await ref
              .read(hiveApiProvider)
              .setPushTarget(
                installId: ref.read(installIdProvider),
                body: PushTarget(kind: 'apns', token: token),
              );
        }
      }
    } else {
      state = PushState(settings: settings, closed: ClosedDelivery.none);
      return;
    }
    state = PushState(
      settings: settings,
      closed: _wantClosed ? ClosedDelivery.on : ClosedDelivery.off,
    );
  }

  /// A UnifiedPush distributor gave this phone an address.
  Future<void> saveEndpoint(String url, String? pubKey, String? auth) async {
    if (pubKey == null || auth == null) return; // can't encrypt for it
    await ref
        .read(hiveApiProvider)
        .setPushTarget(
          installId: ref.read(installIdProvider),
          body: PushTarget(
            kind: 'webpush',
            endpoint: url,
            p256dh: pubKey,
            auth: auth,
          ),
        );
  }

  Future<void> setKind(String kind, bool on) async {
    final s = state.settings;
    if (s == null) return;
    final off = {
      for (final k in s.kinds)
        if (!k.on) k.kind,
    };
    on ? off.remove(kind) : off.add(kind);
    final next = await ref
        .read(hiveApiProvider)
        .setPushSettings(body: PushChoices(off: off.toList()..sort()));
    state = PushState(settings: next, closed: state.closed);
  }

  Future<void> setWhenClosed(bool on) async {
    await ref.read(sharedPreferencesProvider).setBool(_closedKey, on);
    if (!on) {
      try {
        await ref
            .read(hiveApiProvider)
            .deletePushTarget(installId: ref.read(installIdProvider));
        if (_device.android) await _device.unregisterUnifiedPush();
      } catch (_) {}
      state = PushState(settings: state.settings, closed: ClosedDelivery.off);
    } else if (state.settings != null) {
      await _startClosed(state.settings!);
    }
  }
}

final pushProvider = NotifierProvider<PushController, PushState>(
  PushController.new,
);
