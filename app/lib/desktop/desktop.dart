import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/home_connection.dart';
import '../player/player_controller.dart';
import '../player/quality.dart';

/// Computers only: the tray / menu-bar icon, the mini player window,
/// closing the window without stopping the music, and (Windows) the
/// output device and exclusive mode.

bool get _testing =>
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
bool get desktopFeatures => isDesktop && !_testing;
bool get outputChoiceHere =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

// ------------------------------------------------------------------ settings

@immutable
class DesktopSettings {
  const DesktopSettings({
    this.closeToTray = true,
    this.outputDevice = 'auto',
    this.exclusive = false,
  });

  /// Closing the window keeps the music playing (Hive stays in the tray /
  /// menu bar); off: closing quits.
  final bool closeToTray;

  /// mpv's device name; "auto" follows Windows.
  final String outputDevice;

  /// Exclusive mode: Hive alone uses the device, bit-perfect (Windows).
  final bool exclusive;

  DesktopSettings copyWith({
    bool? closeToTray,
    String? outputDevice,
    bool? exclusive,
  }) => DesktopSettings(
    closeToTray: closeToTray ?? this.closeToTray,
    outputDevice: outputDevice ?? this.outputDevice,
    exclusive: exclusive ?? this.exclusive,
  );
}

class DesktopSettingsNotifier extends Notifier<DesktopSettings> {
  static const _close = 'desktop.closeToTray';
  static const _device = 'output.device';
  static const _exclusive = 'output.exclusive';

  @override
  DesktopSettings build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    return DesktopSettings(
      closeToTray: prefs.getBool(_close) ?? true,
      outputDevice: prefs.getString(_device) ?? 'auto',
      exclusive: prefs.getBool(_exclusive) ?? false,
    );
  }

  Future<void> update(DesktopSettings next) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setBool(_close, next.closeToTray);
    await prefs.setString(_device, next.outputDevice);
    await prefs.setBool(_exclusive, next.exclusive);
    state = next;
    await applyOutput(next);
  }
}

final desktopSettingsProvider =
    NotifierProvider<DesktopSettingsNotifier, DesktopSettings>(
      DesktopSettingsNotifier.new,
    );

/// Send the output device and exclusive mode to every player (Windows).
Future<void> applyOutput(DesktopSettings s) async {
  if (!outputChoiceHere || _testing) return;
  await JustAudioMediaKit.setMpvProperty('audio-device', s.outputDevice);
  await JustAudioMediaKit.setMpvProperty(
    'audio-exclusive',
    s.exclusive ? 'yes' : 'no',
  );
}

/// The outputs mpv can play to: (name, what people call it). Empty until
/// something has played once.
List<(String, String)> outputDevices() {
  if (!outputChoiceHere || _testing) return const [];
  return [
    for (final d in JustAudioMediaKit.audioDevices)
      (d.name, d.name == 'auto' ? 'Same as Windows' : d.description),
  ];
}

// ------------------------------------------------------------------ mini window

/// The window shrunk to a small player that stays on top of other windows.
class MiniWindow extends Notifier<bool> {
  Size? _normal;

  @override
  bool build() => false;

  Future<void> toggle() => set(!state);

  Future<void> set(bool mini) async {
    if (mini == state) return;
    if (desktopFeatures) {
      if (mini) {
        _normal = await windowManager.getSize();
        await windowManager.setMinimumSize(const Size(340, 96));
        await windowManager.setSize(const Size(380, 112));
        await windowManager.setAlwaysOnTop(true);
        await windowManager.setResizable(false);
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setResizable(true);
        await windowManager.setMinimumSize(const Size(720, 520));
        await windowManager.setSize(_normal ?? const Size(1200, 800));
      }
    }
    state = mini;
  }
}

final miniWindowProvider = NotifierProvider<MiniWindow, bool>(MiniWindow.new);

// ------------------------------------------------------------------ tray

/// The tray (Windows) or menu bar (Mac) icon: what's playing, play/pause,
/// next, previous, show Hive, the mini player, quit. Closing the window
/// hides it there, and the music carries on.
class DesktopShell with TrayListener, WindowListener {
  DesktopShell(this._ref);
  final Ref _ref;
  String _menuKey = '';

  Future<void> start() async {
    if (!desktopFeatures) return;
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray.ico'
          : 'assets/tray/tray_template.png',
      isTemplate: true,
    );
    await _refresh();
    _ref.listen(playerProvider, (_, _) => unawaited(_refresh()));
    await applyOutput(_ref.read(desktopSettingsProvider));
  }

  PlayerController get _player => _ref.read(playerProvider.notifier);

  Future<void> _refresh() async {
    final s = _ref.read(playerProvider);
    final t = s.track;
    final key = '${t?.id}|${s.playing}|${_ref.read(miniWindowProvider)}';
    if (key == _menuKey) return;
    _menuKey = key;
    await trayManager.setToolTip(
      t == null ? 'Hive' : '${t.title} · ${t.artistName}',
    );
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(
            label: t == null
                ? 'Nothing playing'
                : '${t.title} · ${t.artistName}',
            disabled: true,
          ),
          MenuItem.separator(),
          MenuItem(
            key: 'toggle',
            label: s.playing ? 'Pause' : 'Play',
            disabled: t == null,
          ),
          MenuItem(key: 'next', label: 'Next', disabled: t == null),
          MenuItem(key: 'previous', label: 'Previous', disabled: t == null),
          MenuItem.separator(),
          MenuItem(key: 'show', label: 'Show Hive'),
          MenuItem(
            key: 'mini',
            label: _ref.read(miniWindowProvider)
                ? 'Full window'
                : 'Mini player',
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit Hive'),
        ],
      ),
    );
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onTrayIconMouseDown() {
    // Windows: a click shows Hive; the Mac opens the menu, as menu-bar icons do.
    if (Platform.isWindows) {
      unawaited(_show());
    } else {
      unawaited(trayManager.popUpContextMenu());
    }
  }

  @override
  void onTrayIconRightMouseDown() => unawaited(trayManager.popUpContextMenu());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'toggle':
        unawaited(_player.toggle());
      case 'next':
        unawaited(_player.next());
      case 'previous':
        unawaited(_player.previous());
      case 'show':
        unawaited(_show());
      case 'mini':
        unawaited(
          _show().then((_) => _ref.read(miniWindowProvider.notifier).toggle()),
        );
        _menuKey = '';
      case 'quit':
        unawaited(_quit());
    }
  }

  @override
  void onWindowClose() {
    if (_ref.read(desktopSettingsProvider).closeToTray) {
      unawaited(windowManager.hide());
    } else {
      unawaited(_quit());
    }
  }

  Future<void> _quit() async {
    await _player.stop();
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }
}

final desktopShellProvider = Provider<DesktopShell>((ref) => DesktopShell(ref));
