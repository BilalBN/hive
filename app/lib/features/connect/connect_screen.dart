import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../auth/device_auth.dart';
import '../../core/api.dart';
import '../../core/app_info.dart';
import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../design/widgets.dart';
import 'scan_invite.dart';

/// Unauthenticated calls to a home that isn't saved yet. Replaced in tests.
final joinApiForProvider = Provider<AuthApiFor>(
  (ref) => ref.watch(authApiForProvider),
);

enum _Step { address, email, code, waiting, declined, deviceLimit }

/// Joining home: the address and invite (scanned or typed), the person's
/// email and the 6-digit code sent to it, then waiting for approval when
/// there was no invite. Homes still on M1's development key take that key in
/// place of an invite. Also says when this device was signed out or paused.
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _address = TextEditingController();
  final _invite = TextEditingController();
  final _email = TextEditingController();
  final _deviceName = TextEditingController(text: defaultDeviceName);
  final _code = TextEditingController();

  _Step _step = _Step.address;
  String? _error;
  String? _inviteError;
  bool _busy = false;

  Uri? _home;
  String _homeName = 'home';
  InviteInfo? _inviteInfo;
  String? _inviteCode;
  String? _verificationId;
  bool _emailSent = true;
  DateTime? _resendAt;
  String? _requestId;
  String? _requestToken;
  List<MyDevice> _devices = const [];
  int _swapsLeft = 0;
  Timer? _poll;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    final store = ref.read(homeAddressStoreProvider);
    final saved = store.address;
    if (saved != null) {
      _address.text = saved.toString();
      _home = saved;
    }
    _invite.text = store.key ?? '';
    final pending = store.pending;
    if (pending != null && saved != null) {
      _requestId = pending.id;
      _requestToken = pending.token;
      _deviceName.text = pending.deviceName;
      _step = _Step.waiting;
      _startPolling();
    }
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_step == _Step.code && mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _tick?.cancel();
    for (final c in [_address, _invite, _email, _deviceName, _code]) {
      c.dispose();
    }
    super.dispose();
  }

  HiveApi get _api => ref.read(joinApiForProvider)(_home!);

  void _fail(Object e, {bool invite = false}) {
    final text = e is HiveApiException && e.problem != null
        ? (e.problem!.detail ?? e.problem!.title)
        : describeFailure(e);
    setState(() {
      if (invite) {
        _inviteError = text;
      } else {
        _error = text;
      }
    });
  }

  Future<void> _run(Future<void> Function() body, {bool invite = false}) async {
    setState(() {
      _busy = true;
      _error = null;
      _inviteError = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) _fail(e, invite: invite);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ------------------------------------------------------------ address and invite

  Future<void> _scan() async {
    final text = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const ScanInviteScreen()));
    if (text == null || !mounted) return;
    final link = parseJoinLink(text);
    if (link.address == null || link.code == null) {
      setState(() => _error = "That QR code isn't a Hive invite.");
      return;
    }
    _address.text = link.address.toString();
    _invite.text = link.code!;
    await _connect();
  }

  Future<void> _connect() async {
    final address = parseHomeAddress(_address.text);
    if (address == null) {
      setState(
        () => _error = 'That doesn\'t look like an address. Try something like 100.84.12.7.',
      );
      return;
    }
    final typed = _invite.text.trim();
    await _run(() async {
      final Health health;
      try {
        health = await ref.read(healthCheckProvider)(address);
      } catch (e) {
        _fail(e);
        return;
      }
      _home = address;
      _homeName = health.homeName;
      final devKeyHome =
          health.access == null || health.access == 'developmentKey';
      if (typed.toLowerCase().startsWith('hive-dev-') || devKeyHome) {
        if (!typed.toLowerCase().startsWith('hive-dev-')) {
          setState(
            () => _inviteError = 'This home still uses the key from Hive Admin → Overview. Paste it here.',
          );
          return;
        }
        await _useDevelopmentKey(address, typed);
        return;
      }
      if (typed.isEmpty) {
        _inviteInfo = null;
        _inviteCode = null;
      } else {
        final InviteInfo info;
        try {
          info = await _api.resolveInvite(body: InviteCode(code: typed));
        } on HiveApiException catch (e) {
          setState(
            () => _inviteError = e.status == 404
                ? "That invite code isn't right. Check it and try again."
                : (e.problem?.detail ?? describeFailure(e)),
          );
          return;
        }
        if (!info.valid) {
          setState(
            () => _inviteError =
                'This invite has been used or has run out. Ask for a new one.',
          );
          return;
        }
        _inviteInfo = info;
        _inviteCode = typed;
      }
      setState(() => _step = _Step.email);
    }, invite: false);
  }

  Future<void> _useDevelopmentKey(Uri address, String key) async {
    try {
      await ref.read(keyCheckProvider)(address, key);
    } on HiveApiException catch (e) {
      setState(
        () => _inviteError = e.status == 401
            ? (e.problem?.detail ??
                  "Home didn't accept that key. Check it against Hive Admin → Overview.")
            : describeError(e),
      );
      return;
    }
    await ref.read(homeAddressStoreProvider).save(address, key: key);
    if (mounted) context.go('/home');
  }

  // ------------------------------------------------------------ email and code

  Future<void> _sendCode() async {
    final email = _email.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Type the email address you use.');
      return;
    }
    await _run(() async {
      final started = await _api.startEmailVerification(
        body: EmailStart(
          email: email,
          inviteCode: _inviteCode,
          deviceName: _deviceName.text.trim().isEmpty
              ? defaultDeviceName
              : _deviceName.text.trim(),
          platform: platformWire,
        ),
      );
      _verificationId = started.verificationId;
      _emailSent = started.emailSent;
      _resendAt = DateTime.now().add(
        Duration(seconds: started.resendAfterSeconds),
      );
      _code.clear();
      setState(() => _step = _Step.code);
    });
  }

  Future<void> _verify() async {
    final code = _code.text.trim();
    if (code.length != 6) return;
    await _run(() async {
      final AccessRequestStatus status;
      try {
        status = await _api.verifyEmailCode(
          body: EmailVerify(verificationId: _verificationId!, code: code),
        );
      } on HiveApiException catch (e) {
        final left = e.problem?.attemptsLeft;
        setState(
          () => _error = left != null && left > 0
              ? "That code isn't right. ${left == 1 ? '1 try' : '$left tries'} left."
              : (e.problem?.detail ?? describeFailure(e)),
        );
        return;
      }
      _requestId = status.requestId;
      _requestToken = status.requestToken;
      _homeName = status.homeName;
      await _decided(status);
    });
  }

  Future<void> _decided(AccessRequestStatus status) async {
    final store = ref.read(homeAddressStoreProvider);
    switch (status.status) {
      case 'approved':
        _poll?.cancel();
        await _register();
      case 'declined':
        _poll?.cancel();
        await store.clearPending();
        setState(() => _step = _Step.declined);
      default:
        await store.save(_home!);
        await store.clearKey();
        await store.savePending(
          status.requestId,
          status.requestToken,
          _deviceName.text.trim(),
        );
        setState(() => _step = _Step.waiting);
        _startPolling();
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (_busy || _home == null || _requestId == null) return;
      try {
        final s = await _api.getAccessRequest(
          requestId: _requestId!,
          body: RequestPoll(requestToken: _requestToken!),
        );
        if (s.status != 'pending' && mounted) await _decided(s);
      } catch (_) {
        // Home asleep or the request gone: keep waiting quietly.
      }
    });
  }

  Future<void> _register({String? replace}) async {
    final auth = ref.read(deviceAuthProvider);
    final key = await auth.keyForJoining();
    final DeviceSession session;
    try {
      session = await _api.registerDevice(
        body: DeviceRegistration(
          requestId: _requestId!,
          requestToken: _requestToken!,
          publicKey: await key.publicKey(),
          name: _deviceName.text.trim().isEmpty
              ? defaultDeviceName
              : _deviceName.text.trim(),
          platform: platformWire,
          appVersion: appVersion,
          replaceDeviceId: replace,
        ),
      );
    } on HiveApiException catch (e) {
      if (e.problem?.code == 'deviceLimit') {
        setState(() {
          _devices = e.problem?.devices ?? const [];
          _swapsLeft = e.problem?.swapsLeft ?? 0;
          _step = _Step.deviceLimit;
        });
        return;
      }
      rethrow;
    }
    final store = ref.read(homeAddressStoreProvider);
    await store.clearPending();
    await store.save(_home!);
    await store.clearKey();
    await auth.adopt(session);
    if (mounted) context.go('/home');
  }

  void _restart() {
    _poll?.cancel();
    ref.read(homeAddressStoreProvider).clearPending();
    setState(() {
      _step = _Step.address;
      _error = null;
      _requestId = _requestToken = _verificationId = null;
    });
  }

  // ------------------------------------------------------------ screens

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    final auth = ref.watch(deviceAuthProvider);
    final body = auth.problem == SignInProblem.suspended
        ? _paused(p, auth)
        : switch (_step) {
            _Step.address => _addressStep(p, auth),
            _Step.email => _emailStep(p),
            _Step.code => _codeStep(p),
            _Step.waiting => _waitingStep(p),
            _Step.declined => _declinedStep(p),
            _Step.deviceLimit => _deviceLimitStep(p),
          };
    return PopScope(
      canPop: _step == _Step.address,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() {
          _error = null;
          _step = switch (_step) {
            _Step.code => _Step.email,
            _ => _Step.address,
          };
        });
      },
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(
                padding: const EdgeInsets.all(HiveSpace.lg),
                shrinkWrap: true,
                children: body,
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _header(
    HivePalette p,
    IconData icon,
    String title,
    String text,
  ) => [
    Icon(icon, size: 32, color: p.accent),
    const SizedBox(height: HiveSpace.md),
    Semantics(
      header: true,
      child: Text(title, style: HiveType.title1.copyWith(color: p.textPrimary)),
    ),
    const SizedBox(height: HiveSpace.xs),
    Text(text, style: HiveType.body.copyWith(color: p.textSecondary)),
    const SizedBox(height: HiveSpace.lg),
  ];

  Widget _errorText(HivePalette p, String? error) => error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: HiveSpace.xs),
          child: Text(error, style: HiveType.callout.copyWith(color: p.danger)),
        );

  Widget _label(HivePalette p, String text) => Padding(
    padding: const EdgeInsets.only(bottom: HiveSpace.xs, top: HiveSpace.md),
    child: Text(text, style: HiveType.callout.copyWith(color: p.textSecondary)),
  );

  Widget _back(String label, VoidCallback onTap) => Center(
    child: TextButton(onPressed: _busy ? null : onTap, child: Text(label)),
  );

  List<Widget> _addressStep(HivePalette p, DeviceAuth auth) => [
    ..._header(
      p,
      HiveIcons.house,
      'Connect to home',
      auth.problem == SignInProblem.revoked
          ? 'This device was signed out of Hive. Join again with your invite, or just your email.'
          : 'Use the invite from whoever runs Hive: scan its QR code, or type the address and code. Tailscale needs to be on.',
    ),
    if (canScanQr) ...[
      HivePrimaryButton(
        label: 'Scan the invite',
        busy: _busy,
        onPressed: _scan,
      ),
      const SizedBox(height: HiveSpace.md),
      Text(
        'Or type it',
        textAlign: TextAlign.center,
        style: HiveType.caption.copyWith(color: p.textTertiary),
      ),
    ],
    _label(p, 'Home address'),
    TextField(
      key: const Key('address'),
      controller: _address,
      autofocus: !canScanQr,
      keyboardType: TextInputType.url,
      autocorrect: false,
      textInputAction: TextInputAction.next,
      style: HiveType.body.copyWith(color: p.textPrimary),
      decoration: _field(
        p,
        hint: '100.84.12.7 or hive-pc:8443',
        error: _error != null,
      ),
    ),
    _errorText(p, _error),
    _label(p, 'Invite code'),
    TextField(
      key: const Key('dev-key'),
      controller: _invite,
      autocorrect: false,
      enableSuggestions: false,
      textCapitalization: TextCapitalization.characters,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _connect(),
      style: HiveType.body.copyWith(color: p.textPrimary),
      decoration: _field(
        p,
        hint: 'HIVE-XXXX-XXXX',
        error: _inviteError != null,
      ),
    ),
    Padding(
      padding: const EdgeInsets.only(top: HiveSpace.xs),
      child: Text(
        _inviteError ??
            'No invite? Leave it empty: whoever runs Hive lets you in instead.',
        style: HiveType.caption.copyWith(
          color: _inviteError == null ? p.textTertiary : p.danger,
        ),
      ),
    ),
    const SizedBox(height: HiveSpace.lg),
    HivePrimaryButton(
      label: 'Connect',
      busy: _busy && !canScanQr,
      onPressed: _connect,
    ),
  ];

  List<Widget> _emailStep(HivePalette p) => [
    ..._header(
      p,
      HiveIcons.mail,
      'Join $_homeName',
      _inviteInfo?.email != null
          ? 'This invite is for ${_inviteInfo!.email}. Type that email and we\'ll send a code to it.'
          : 'Type your email and we\'ll send a 6-digit code to it.',
    ),
    _label(p, 'Your email'),
    TextField(
      key: const Key('email'),
      controller: _email,
      autofocus: true,
      keyboardType: TextInputType.emailAddress,
      autocorrect: false,
      textInputAction: TextInputAction.next,
      autofillHints: const [AutofillHints.email],
      style: HiveType.body.copyWith(color: p.textPrimary),
      decoration: _field(p, hint: 'you@example.com', error: _error != null),
    ),
    _errorText(p, _error),
    _label(p, 'Name for this device'),
    TextField(
      key: const Key('device-name'),
      controller: _deviceName,
      textInputAction: TextInputAction.go,
      onSubmitted: (_) => _sendCode(),
      style: HiveType.body.copyWith(color: p.textPrimary),
      decoration: _field(p, hint: defaultDeviceName, error: false),
    ),
    const SizedBox(height: HiveSpace.lg),
    HivePrimaryButton(
      label: 'Send me a code',
      busy: _busy,
      onPressed: _sendCode,
    ),
    const SizedBox(height: HiveSpace.sm),
    _back('Back', () => setState(() => _step = _Step.address)),
  ];

  List<Widget> _codeStep(HivePalette p) {
    final wait = _resendAt?.difference(DateTime.now()).inSeconds ?? 0;
    return [
      ..._header(
        p,
        HiveIcons.mailOpen,
        _emailSent ? 'Check your email' : 'Ask for your code',
        _emailSent
            ? 'We sent a 6-digit code to ${_email.text.trim()}. It works for 10 minutes.'
            : 'Email isn\'t set up at home yet, so whoever runs Hive will tell you your code. It\'s on Hive Admin → Requests.',
      ),
      TextField(
        key: const Key('code'),
        controller: _code,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        autofillHints: const [AutofillHints.oneTimeCode],
        textAlign: TextAlign.center,
        onChanged: (v) {
          if (v.length == 6) _verify();
        },
        style: HiveType.title1.copyWith(
          color: p.textPrimary,
          letterSpacing: 8,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        decoration: _field(p, hint: '000000', error: _error != null),
      ),
      _errorText(p, _error),
      const SizedBox(height: HiveSpace.lg),
      HivePrimaryButton(label: 'Continue', busy: _busy, onPressed: _verify),
      const SizedBox(height: HiveSpace.sm),
      _back(
        wait > 0 ? 'Send a new code in ${wait}s' : 'Send a new code',
        wait > 0 ? () {} : _sendCode,
      ),
      _back('Use a different email', () => setState(() => _step = _Step.email)),
    ];
  }

  List<Widget> _waitingStep(HivePalette p) => [
    ..._header(
      p,
      HiveIcons.hourglass,
      'Waiting to be let in',
      'Whoever runs $_homeName has been told you\'re waiting. This moves on by itself once they let you in; you can close Hive and come back.',
    ),
    const Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
    const SizedBox(height: HiveSpace.lg),
    _back('Start again', _restart),
  ];

  List<Widget> _declinedStep(HivePalette p) => [
    ..._header(
      p,
      HiveIcons.circleX,
      'Not let in',
      'Whoever runs $_homeName didn\'t let this device in. If that\'s a mistake, ask them for an invite.',
    ),
    HivePrimaryButton(label: 'Start again', onPressed: _restart),
  ];

  List<Widget> _deviceLimitStep(HivePalette p) => [
    ..._header(
      p,
      HiveIcons.smartphone,
      'All your devices are in use',
      _swapsLeft > 0
          ? 'Replace one of them with this device. You can swap ${_swapsLeft == 1 ? 'once more' : '$_swapsLeft more times'} this month.'
          : 'You\'ve swapped devices as often as this home allows this month. Ask whoever runs Hive to remove one for you.',
    ),
    for (final d in _devices)
      Padding(
        padding: const EdgeInsets.only(bottom: HiveSpace.xs),
        child: Material(
          color: p.surface,
          borderRadius: BorderRadius.circular(HiveRadius.card),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              HiveSpace.md,
              HiveSpace.sm,
              HiveSpace.xs,
              HiveSpace.sm,
            ),
            child: Row(
              children: [
                Icon(HiveIcons.smartphone, size: 20, color: p.textSecondary),
                const SizedBox(width: HiveSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d.name,
                        style: HiveType.body.copyWith(color: p.textPrimary),
                      ),
                      Text(
                        d.lastSeenAt == null
                            ? d.platform
                            : 'Last used ${_ago(d.lastSeenAt!)}',
                        style: HiveType.caption.copyWith(
                          color: p.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_swapsLeft > 0)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() => _register(replace: d.id)),
                    child: const Text('Replace'),
                  ),
              ],
            ),
          ),
        ),
      ),
    _errorText(p, _error),
    const SizedBox(height: HiveSpace.md),
    _back('Start again', _restart),
  ];

  List<Widget> _paused(HivePalette p, DeviceAuth auth) => [
    ..._header(
      p,
      HiveIcons.circlePause,
      'Access paused',
      auth.problemDetail ?? 'Whoever runs this home has paused your access. Nothing is deleted; ask them about it.',
    ),
    HivePrimaryButton(
      label: 'Try again',
      busy: _busy,
      onPressed: () => _run(auth.retry),
    ),
  ];

  static String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inDays >= 1) {
      return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
    }
    if (d.inHours >= 1) return '${d.inHours} hr ago';
    return 'recently';
  }

  InputDecoration _field(
    HivePalette p, {
    required String hint,
    required bool error,
  }) => InputDecoration(
    hintText: hint,
    hintStyle: HiveType.body.copyWith(color: p.textTertiary),
    filled: true,
    fillColor: p.surface,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: HiveSpace.md,
      vertical: HiveSpace.md,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(HiveRadius.card),
      borderSide: BorderSide(color: error ? p.danger : p.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(HiveRadius.card),
      borderSide: BorderSide(color: error ? p.danger : p.accent, width: 1.5),
    ),
  );
}
