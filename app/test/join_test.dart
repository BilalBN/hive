import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/api/hive_api.g.dart';
import 'package:hive/app.dart';
import 'package:hive/auth/device_auth.dart';
import 'package:hive/auth/device_key.dart';
import 'package:hive/auth/secret_store.dart';
import 'package:hive/core/app_info.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_home.dart';

Health invitesHealth([String name = "Arun's home"]) => Health(
  status: 'ok',
  homeName: name,
  serverVersion: '0.2.0',
  apiVersion: '0.3.0',
  minAppVersion: '0.1.0',
  access: 'invites',
  serverTime: DateTime.utc(2026, 10, 19),
);

const me = Me(
  id: 'u1',
  name: 'Basith',
  email: 'basith@example.com',
  role: 'member',
  simpleMode: false,
);

Map<String, Object?> session({
  String access = 'access-1',
  String refresh = 'refresh-1',
  Duration lasts = const Duration(minutes: 15),
}) => DeviceSession(
  deviceId: 'dev-1',
  accessToken: access,
  accessExpiresAt: DateTime.now().add(lasts),
  refreshToken: refresh,
  refreshExpiresAt: DateTime.now().add(const Duration(days: 30)),
  me: me,
).toJson();

Map<String, dynamic> bodyOf(RequestOptions o) => o.data is String
    ? (jsonDecode(o.data as String) as Map).cast<String, dynamic>()
    : (o.data as Map).cast<String, dynamic>();

/// A home that lets an invited person in at once.
FakeHomeAdapter invitedHome({String status = 'approved'}) {
  final fake = FakeHomeAdapter();
  fake.extra.addAll({
    'POST /api/v1/auth/invites/resolve': (o) {
      if (bodyOf(o)['code'] != 'HIVE-7K2Q-9MXP') {
        throw FakeProblem(404, {'title': 'Invite not found', 'status': 404});
      }
      return const InviteInfo(
        homeName: "Arun's home",
        valid: true,
        email: 'b***@example.com',
      ).toJson();
    },
    'POST /api/v1/auth/email/start': (o) => EmailStarted(
      verificationId: 'v1',
      expiresAt: DateTime.now().add(const Duration(minutes: 10)),
      resendAfterSeconds: 30,
      emailSent: true,
    ).toJson(),
    'POST /api/v1/auth/email/verify': (o) {
      if (bodyOf(o)['code'] != '123456') {
        throw FakeProblem(400, {
          'title': 'Wrong code',
          'status': 400,
          'attemptsLeft': 4,
        });
      }
      return AccessRequestStatus(
        requestId: 'r1',
        requestToken: 'rt1',
        status: status,
        homeName: "Arun's home",
      ).toJson();
    },
    'POST /api/v1/auth/devices': (o) => session(),
  });
  return fake;
}

Future<void> pumpJoin(
  WidgetTester tester,
  FakeHomeAdapter fake, {
  MemorySecretStore? secrets,
  bool connected = false,
  Map<String, Object> prefs = const {},
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final overrides = await fakeHomeOverrides(
    check: (_) async => invitesHealth(),
    adapter: fake,
    connected: connected,
    prefs: prefs,
    secrets: secrets,
  );
  await tester.pumpWidget(
    ProviderScope(overrides: overrides, child: const HiveApp()),
  );
  await tester.pumpAndSettle();
}

Future<void> typeInviteAndEmail(
  WidgetTester tester, {
  String code = 'HIVE-7K2Q-9MXP',
}) async {
  await tester.enterText(find.byKey(const Key('address')), '100.84.12.7');
  await tester.enterText(find.byKey(const Key('dev-key')), code);
  await tester.tap(find.text('Connect'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an invited person joins with their email and a code', (
    tester,
  ) async {
    final fake = invitedHome();
    final secrets = MemorySecretStore();
    await pumpJoin(tester, fake, secrets: secrets);

    await typeInviteAndEmail(tester);
    expect(find.text("Join Arun's home"), findsOneWidget);
    expect(find.textContaining('b***@example.com'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('email')),
      'basith@example.com',
    );
    await tester.enterText(
      find.byKey(const Key('device-name')),
      "Basith's Pixel",
    );
    await tester.tap(find.text('Send me a code'));
    await tester.pumpAndSettle();
    expect(find.text('Check your email'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('code')), '111111');
    await tester.pumpAndSettle();
    expect(find.textContaining('4 tries left'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.pumpAndSettle();

    // In: Home shows, and calls carry this device's token, not a key.
    expect(find.text('Connected to home'), findsOneWidget);
    expect(fake.authorizations.last, 'Bearer access-1');
    expect(secrets.values['auth.refreshToken'], 'refresh-1');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('home.address'), 'http://100.84.12.7:8443');
    expect(prefs.getString('home.developmentKey'), isNull);

    final i = fake.requests.indexOf('POST /api/v1/auth/devices');
    expect(i, greaterThan(0));
  });

  testWidgets('the device registers an Ed25519 key it can sign with', (
    tester,
  ) async {
    final fake = invitedHome();
    Map<String, dynamic>? registration;
    fake.extra['POST /api/v1/auth/devices'] = (o) {
      registration = bodyOf(o);
      return session();
    };
    final secrets = MemorySecretStore();
    await pumpJoin(tester, fake, secrets: secrets);
    await typeInviteAndEmail(tester);
    await tester.enterText(
      find.byKey(const Key('email')),
      'basith@example.com',
    );
    await tester.tap(find.text('Send me a code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.pumpAndSettle();

    expect(registration!['requestId'], 'r1');
    expect(registration!['requestToken'], 'rt1');
    expect(registration!['platform'], platformWire);
    expect(registration!['appVersion'], appVersion);
    final public = unb64(registration!['publicKey'] as String);
    expect(public, hasLength(32));
    final key = await DeviceKey.fromSeed(secrets.values['auth.deviceKey']!);
    final sig = await key.sign('challenge-abc');
    final ok = await Ed25519().verify(
      utf8.encode('challenge-abc'),
      signature: Signature(
        unb64(sig),
        publicKey: SimplePublicKey(public, type: KeyPairType.ed25519),
      ),
    );
    expect(ok, isTrue);
  });

  testWidgets('without an invite, the app waits until the admin lets them in', (
    tester,
  ) async {
    final fake = invitedHome(status: 'pending');
    var decided = false;
    fake.extra['POST /api/v1/auth/requests/r1'] = (o) => AccessRequestStatus(
      requestId: 'r1',
      requestToken: 'rt1',
      status: decided ? 'approved' : 'pending',
      homeName: "Arun's home",
    ).toJson();
    await pumpJoin(tester, fake);
    await typeInviteAndEmail(tester, code: '');
    await tester.enterText(
      find.byKey(const Key('email')),
      'basith@example.com',
    );
    await tester.tap(find.text('Send me a code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Waiting to be let in'), findsOneWidget);

    decided = true;
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Connected to home'), findsOneWidget);
  });

  testWidgets('with every device in use, one is swapped out', (tester) async {
    final fake = invitedHome();
    String? replaced;
    fake.extra['POST /api/v1/auth/devices'] = (o) {
      replaced = bodyOf(o)['replaceDeviceId'] as String?;
      if (replaced == null) {
        throw FakeProblem(409, {
          'title': 'All devices in use',
          'status': 409,
          'code': 'deviceLimit',
          'swapsLeft': 2,
          'devices': [
            MyDevice(
              id: 'old-phone',
              name: 'Old phone',
              platform: 'android',
              current: false,
              createdAt: DateTime.utc(2026, 1, 1),
            ).toJson(),
          ],
        });
      }
      return session();
    };
    await pumpJoin(tester, fake);
    await typeInviteAndEmail(tester);
    await tester.enterText(
      find.byKey(const Key('email')),
      'basith@example.com',
    );
    await tester.tap(find.text('Send me a code'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('code')), '123456');
    await tester.pumpAndSettle();
    expect(find.text('All your devices are in use'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(replaced, 'old-phone');
    expect(find.text('Connected to home'), findsOneWidget);
  });

  testWidgets('a wrong invite code says so', (tester) async {
    await pumpJoin(tester, invitedHome());
    await typeInviteAndEmail(tester, code: 'HIVE-AAAA-BBBB');
    expect(find.textContaining("invite code isn't right"), findsOneWidget);
  });

  testWidgets('an old development key is turned away once home uses invites', (
    tester,
  ) async {
    await pumpJoin(tester, FakeHomeAdapter(), connected: true);
    expect(find.text('Connect to home'), findsOneWidget);
  });

  testWidgets('a signed-out device is told so and can join again', (
    tester,
  ) async {
    final secrets = MemorySecretStore();
    final key = await DeviceKey.generate();
    secrets.values.addAll({
      'auth.deviceId': 'dev-1',
      'auth.refreshToken': 'refresh-1',
      'auth.deviceKey': key.seed,
      'auth.me': jsonEncode(me.toJson()),
    });
    final fake = FakeHomeAdapter();
    fake.extra['POST /api/v1/auth/challenge'] = (o) => throw FakeProblem(401, {
      'title': 'Signed out',
      'status': 401,
      'code': 'revoked',
      'detail': 'This device was removed.',
    });
    await pumpJoin(
      tester,
      fake,
      secrets: secrets,
      prefs: {'home.address': 'http://100.84.12.7:8443'},
    );
    await tester.pumpAndSettle();
    expect(find.text('Connect to home'), findsOneWidget);
    expect(find.textContaining('This device was signed out'), findsOneWidget);
    expect(secrets.values['auth.refreshToken'], isNull);
  });

  group('DeviceAuth', () {
    test('refreshes an expired token with a fresh signature', () async {
      final secrets = MemorySecretStore();
      final fake = FakeHomeAdapter();
      Map<String, dynamic>? sent;
      fake.extra['POST /api/v1/auth/challenge'] = (o) => Challenge(
        challenge: 'ch-1',
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ).toJson();
      fake.extra['POST /api/v1/auth/token'] = (o) {
        sent = bodyOf(o);
        return session(access: 'access-2', refresh: 'refresh-2');
      };
      final auth = DeviceAuth(
        secrets,
        (a) => HiveApi(
          Dio(BaseOptions(baseUrl: a.toString()))..httpClientAdapter = fake,
        ),
        () => Uri.parse('http://100.84.12.7:8443'),
      );
      await auth.load();
      final key = await auth.keyForJoining();
      await auth.adopt(
        DeviceSession.fromJson(session(lasts: const Duration(seconds: -1))),
      );
      expect(await auth.accessToken(), 'access-2');
      expect(sent!['deviceId'], 'dev-1');
      expect(sent!['refreshToken'], 'refresh-1');
      expect(sent!['challenge'], 'ch-1');
      expect(sent!['signature'], await key.sign('ch-1'));
      expect(secrets.values['auth.refreshToken'], 'refresh-2');
      auth.dispose();
    });

    test('paused access keeps the device for when it comes back', () async {
      final secrets = MemorySecretStore();
      final fake = FakeHomeAdapter();
      fake.extra['POST /api/v1/auth/challenge'] = (o) => throw FakeProblem(
        401,
        {'title': 'Access paused', 'status': 401, 'code': 'suspended'},
      );
      final auth = DeviceAuth(
        secrets,
        (a) => HiveApi(
          Dio(BaseOptions(baseUrl: a.toString()))..httpClientAdapter = fake,
        ),
        () => Uri.parse('http://100.84.12.7:8443'),
      );
      await auth.load();
      await auth.keyForJoining();
      await auth.adopt(
        DeviceSession.fromJson(session(lasts: const Duration(seconds: -1))),
      );
      expect(await auth.accessToken(), isNull);
      expect(auth.problem, SignInProblem.suspended);
      expect(auth.signedIn, isTrue);
      auth.dispose();
    });
  });

  test('app version matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('version: $appVersion+'));
  });

  test('versions compare by number', () {
    expect(isOlder('0.1.9', '0.2.0'), isTrue);
    expect(isOlder('0.10.0', '0.2.0'), isFalse);
    expect(isOlder('0.2.0', '0.2.0'), isFalse);
  });

  test('invite QR links carry the address and code', () {
    final l = parseJoinLink(
      'hive://join?a=http%3A%2F%2F100.84.12.7%3A8443&c=HIVE-7K2Q-9MXP',
    );
    expect(l.address.toString(), 'http://100.84.12.7:8443');
    expect(l.code, 'HIVE-7K2Q-9MXP');
    expect(parseJoinLink('https://example.com').code, isNull);
  });
}
