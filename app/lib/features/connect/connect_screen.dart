import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(homeAddressStoreProvider).address;
    if (saved != null) _controller.text = saved.toString();
  }

  @override
  void dispose() {
    _controller.dispose();
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
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(healthCheckProvider)(address);
      await ref.read(homeAddressStoreProvider).save(address);
      if (mounted) context.go('/home');
    } catch (e) {
      setState(() => _error = describeFailure(e));
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
                  decoration: InputDecoration(
                    hintText: '100.84.12.7 or hive-pc:8443',
                    hintStyle: HiveType.body.copyWith(color: p.textTertiary),
                    filled: true,
                    fillColor: p.surface,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: HiveSpace.md,
                      vertical: HiveSpace.md,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(HiveRadius.card),
                      borderSide: BorderSide(
                        color: _error == null ? p.border : p.danger,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(HiveRadius.card),
                      borderSide: BorderSide(
                        color: _error == null ? p.accent : p.danger,
                        width: 1.5,
                      ),
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: HiveSpace.xs),
                  Text(
                    _error!,
                    style: HiveType.callout.copyWith(color: p.danger),
                  ),
                ],
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
}
