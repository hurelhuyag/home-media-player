import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'config.dart';
import 'remote.dart';
import 'screens/launcher_screen.dart';
import 'standby.dart';
import 'widgets.dart';
import 'youtube.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();

  final config = Config.instance;
  if (config.debugKeys) {
    HardwareKeyboard.instance.addHandler((event) {
      debugPrint('key: ${event.runtimeType} logical=${event.logicalKey.debugName} '
          'physical=${event.physicalKey.debugName}');
      return false;
    });
  }

  GlobalRemoteListener(
    deviceName: config.remoteDeviceName,
    onKeyDown: (code) {
      final standby = Standby.instance;
      switch (code) {
        case GlobalRemoteListener.keyScreenSaver:
          standby.enter();
        case GlobalRemoteListener.keyPauseCd:
          break; // the player or YouTube pauses itself
        case GlobalRemoteListener.keyHome when !standby.isActive:
          // HOME always returns to the launcher, even from YouTube
          if (YouTube.instance.isRunning) {
            YouTube.instance.close();
          } else {
            navigatorKey.currentState?.popUntil((r) => r.isFirst);
          }
        default:
          // The TV switching back to us, or any remote key, wakes it up
          standby.exit();
      }
    },
  ).start();

  runApp(const HomeMediaPlayerApp());
}

class _BackIntent extends Intent {
  const _BackIntent();
}

class _HomeIntent extends Intent {
  const _HomeIntent();
}

class HomeMediaPlayerApp extends StatelessWidget {
  const HomeMediaPlayerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Home Media Player',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        fontFamily: 'NotoSans',
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.red, brightness: Brightness.dark),
        scaffoldBackgroundColor: Colors.black,
        useMaterial3: true,
      ),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(textScaler: TextScaler.linear(Config.instance.textScale)),
          child: Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.escape): _BackIntent(),
              SingleActivator(LogicalKeyboardKey.goBack): _BackIntent(),
              SingleActivator(LogicalKeyboardKey.backspace): _BackIntent(),
              SingleActivator(LogicalKeyboardKey.home): _HomeIntent(),
            },
            child: Actions(
              actions: {
                _BackIntent: CallbackAction<_BackIntent>(
                  onInvoke: (_) => navigatorKey.currentState?.maybePop(),
                ),
                _HomeIntent: CallbackAction<_HomeIntent>(
                  onInvoke: (_) => navigatorKey.currentState?.popUntil((r) => r.isFirst),
                ),
              },
              child: AutoHidePointer(child: child!),
            ),
          ),
        );
      },
      home: const LauncherScreen(),
    );
  }
}
