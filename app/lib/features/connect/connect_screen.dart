import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../api/hive_api.g.dart';
import '../../core/api.dart';
import '../../core/home_connection.dart';
import '../../design/icons.g.dart';
import '../../design/theme.dart';
import '../../design/tokens.g.dart';
import '../../design/widgets.dart';

/// Connect to home by typing its address.
///
/// This is the development version of onboarding: from M2 the address arrives
/// inside the invite (QR code or typed code) and this screen becomes
/// "Type the invite code".
class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _controller = TextEditingController();
  final _keyController = TextEditingController();
  String? _error;
  String? _keyError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final store = ref.read(homeAddressStoreProvider);
    final saved = store.address;
    if (saved != null) _controller.text = saved.toString();
    _keyController.text = store.key ?? '';
  }

  @override
  void dispose() {
    _controller.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final address = parseHomeAddress(_controller.text);
    if (address == null) {
      setState(
        () => _error = 'That doesn\'t look like an address. Try something like 100.84.12.7.',
      );
      return;
    }
    final key = _keyController.text.trim();
    if (key.isEmpty) {
      setState(
        () => _keyError =
            'Copy the key from Hive Admin → Overview on the home computer.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _keyError = null;
    });
    try {
      await ref.read(healthCheckProvider)(address);
    } catch (e) {
      setState(() {
        _error = describeFailure(e);
        _busy = false;
      });
      return;
    }
    try {
      await ref.read(keyCheckProvider)(address, key);
      await ref.read(homeAddressStoreProvider).save(address, key: key);
      if (mounted) context.go('/home');
    } on HiveApiException catch (e) {
      setState(
        () => _keyError = e.status == 401
            ? "Home didn't accept that key. Check it against Hive Admin → Overview."
            : describeError(e),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = HiveTheme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(HiveSpace.lg),
              shrinkWrap: true,
              children: [
                Icon(HiveIcons.house, size: 32, color: p.accent),
                const SizedBox(height: HiveSpace.md),
                Text(
                  'Connect to home',
                  style: HiveType.title1.copyWith(color: p.textPrimary),
                ),
                const SizedBox(height: HiveSpace.xs),
                Text(
                  'Type the address of the music PC at home. The private connection app needs to be on.',
                  style: HiveType.body.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: HiveSpace.lg),
                TextField(
                  key: const Key('address'),
                  controller: _controller,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  style: HiveType.body.copyWith(color: p.textPrimary),
                  decoration: _fieldDecoration(
                    p,
                    hint: '100.84.12.7 or hive-pc:8443',
                    error: _error != null,
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: HiveSpace.xs),
                  Text(
                    _error!,
                    style: HiveType.callout.copyWith(color: p.danger),
                  ),
                ],
                const SizedBox(height: HiveSpace.md),
                Text(
                  'Key from Hive Admin',
                  style: HiveType.callout.copyWith(color: p.textSecondary),
                ),
                const SizedBox(height: HiveSpace.xs),
                TextField(
                  key: const Key('dev-key'),
                  controller: _keyController,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  style: HiveType.body.copyWith(color: p.textPrimary),
                  decoration: _fieldDecoration(
                    p,
                    hint: 'hive-dev-xxxx-xxxx-xxxx-xxxx',
                    error: _keyError != null,
                  ),
                ),
                const SizedBox(height: HiveSpace.xs),
                Text(
                  _keyError ?? 'Shown on the Overview page of Hive Admin. Needed until invites arrive.',
                  style: HiveType.caption.copyWith(
                    color: _keyError == null ? p.textTertiary : p.danger,
                  ),
                ),
                const SizedBox(height: HiveSpace.lg),
                HivePrimaryButton(
                  label: 'Connect',
                  busy: _busy,
                  onPressed: _connect,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration _fieldDecoration(
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
