import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../bootstrap.dart';
import 'shell/app_shell.dart';

final class KenaiApp extends StatefulWidget {
  const KenaiApp({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<KenaiApp> createState() => _KenaiAppState();
}

final class _KenaiAppState extends State<KenaiApp> {
  AppSettings _settings = const AppSettings.defaults();
  StreamSubscription<AppSettings>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.dependencies.settingsRepository.changes.listen(
      (AppSettings settings) {
        if (mounted) setState(() => _settings = settings);
      },
    );
    unawaited(_restore());
    unawaited(widget.dependencies.automation?.start().catchError((Object _) {
      if (!mounted) return;
      // Surface initialization failure rather than silently enabling controls.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _messenger.currentState?.showSnackBar(
          const SnackBar(
              content: Text(
                  'Не удалось применить системные настройки. Проверьте службу Kenai VPN.')),
        );
      });
    }));
  }

  @override
  void dispose() {
    unawaited(widget.dependencies.automation?.dispose());
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        scaffoldMessengerKey: _messenger,
        title: 'Kenai VPN',
        debugShowCheckedModeBanner: false,
        theme: KenaiTheme.light(),
        darkTheme: KenaiTheme.dark(),
        themeMode: switch (_settings.theme) {
          ThemePreference.system => ThemeMode.system,
          ThemePreference.light => ThemeMode.light,
          ThemePreference.dark => ThemeMode.dark,
        },
        home: AppShell(dependencies: widget.dependencies),
      );

  final _messenger = GlobalKey<ScaffoldMessengerState>();

  Future<void> _restore() async {
    final AppSettings settings =
        await widget.dependencies.settingsRepository.load();
    if (mounted) setState(() => _settings = settings);
  }
}
