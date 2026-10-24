// M6: notifications: shown inside Hive while it's open, chosen in Settings,
// and set up for when Hive is closed (UnifiedPush on Android, Apple push on
// iPhones).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/push/push.dart';
import 'package:hive/sync/continuity.dart';

import 'app_test.dart' show health;
import 'support/fake_home.dart';
import 'support/fakes.dart';

const vapid = 'BOrandomvapidkey';
const install = 'install-test-1234';

Map<String, dynamic> settings({
  Set<String> off = const {},
  bool apns = false,
}) => PushSettings(
  webPushKey: vapid,
  apns: apns,
  kinds: [
    for (final (k, label) in [
      ('new_music', 'New music at home'),
      ('request_added', 'A song you asked for was added'),
    ])
      PushKind(kind: k, label: label, on: !off.contains(k)),
  ],
).toJson();

Future<(FakeHomeAdapter, FakeSessionLink, ProviderContainer)> pump(
  WidgetTester tester, {
  FakePushDevice? device,
  bool apns = false,
  FakeHomeAdapter? adapter,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  adapter ??= FakeHomeAdapter();
  var off = <String>{};
  adapter.extra['GET /api/v1/push/settings'] = (o) =>
      settings(off: off, apns: apns);
  adapter.extra['PUT /api/v1/push/settings'] = (o) {
    off = {...((o.data as Map)['off'] as List).cast<String>()};
    return settings(off: off, apns: apns);
  };
  final link = FakeSessionLink();
  final overrides = await fakeHomeOverrides(
    check: (_) async => health("Arun's home"),
    adapter: adapter,
    sessions: link,
    push: device,
    engine: FakeEngine(),
    prefs: {'app.installId': install},
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
  return (
    adapter,
    link,
    ProviderScope.containerOf(tester.element(find.byType(HiveApp))),
  );
}

void main() {
  testWidgets('a notification while Hive is open shows inside it', (
    tester,
  ) async {
    final (_, link, _) = await pump(tester);
    link.say(
      const NoticeReceived(
        'new_music',
        'New music at home',
        "Open Hive to see what's new.",
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('New music at home'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 5));
  });

  testWidgets('Settings chooses which notifications come', (tester) async {
    final (adapter, _, _) = await pump(tester);
    Object? sent;
    final put = adapter.extra['PUT /api/v1/push/settings']!;
    adapter.extra['PUT /api/v1/push/settings'] = (o) {
      sent = o.data;
      return put(o);
    };
    await tester.tap(find.byKey(const Key('open-settings')));
    await tester.pumpAndSettle();
    final tile = find.widgetWithText(SwitchListTile, 'New music at home');
    await tester.scrollUntilVisible(
      tile,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(sent, {
      'off': ['new_music'],
    });
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets(
    'Android: registered with UnifiedPush, and the address goes home',
    (tester) async {
      final device = FakePushDevice(android: true);
      final adapter = FakeHomeAdapter();
      Object? target;
      adapter.extra['PUT /api/v1/push/targets/$install'] = (o) {
        target = o.data;
        return null;
      };
      final (_, _, c) = await pump(tester, device: device, adapter: adapter);
      expect(device.registered, [vapid]);
      // The distributor hands over an address.
      device.onEndpoint!('https://ntfy.sh/upAbc', 'BPkey', 'authsecret');
      await tester.pumpAndSettle();
      expect(target, {
        'kind': 'webpush',
        'endpoint': 'https://ntfy.sh/upAbc',
        'p256dh': 'BPkey',
        'auth': 'authsecret',
      });
      expect(c.read(pushProvider).closed, ClosedDelivery.on);
    },
  );

  testWidgets('Android without a UnifiedPush app says what to install', (
    tester,
  ) async {
    final device = FakePushDevice(android: true, distributor: false);
    final (_, _, c) = await pump(tester, device: device);
    expect(c.read(pushProvider).closed, ClosedDelivery.needsDistributor);
    expect(device.registered, isEmpty);
  });

  testWidgets('iPhone: Apple push once home can send it', (tester) async {
    final device = FakePushDevice(apple: true, token: 'abcdef0123');
    final adapter = FakeHomeAdapter();
    Object? target;
    adapter.extra['PUT /api/v1/push/targets/$install'] = (o) {
      target = o.data;
      return null;
    };
    final (_, _, c) = await pump(
      tester,
      device: device,
      apns: true,
      adapter: adapter,
    );
    expect(target, {'kind': 'apns', 'token': 'abcdef0123'});
    expect(c.read(pushProvider).closed, ClosedDelivery.on);
  });
}
