import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';
import 'privacy_policy_screen.dart';

final class AppSettingsScreen extends StatefulWidget {
  const AppSettingsScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

final class _AppSettingsScreenState extends State<AppSettingsScreen> {
  AppSettings _settings = const AppSettings.defaults();
  bool _loading = true;
  bool _checkingUpdates = false;
  bool _saving = false;
  UpdateCheckResult? _updateResult;
  String? _safeError;

  bool get _safeAutomaticUpdates =>
      widget.dependencies.updateProvider.isAvailable &&
      !widget.dependencies.updateProvider.isMock &&
      widget.dependencies.updateProvider.verifiesSignatures;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(KenaiSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Параметры',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                if (widget.dependencies.updateProvider.isMock)
                  const Chip(label: Text('Mock-проверка обновлений')),
              ],
            ),
            const SizedBox(height: KenaiSpacing.lg),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : AbsorbPointer(
                      absorbing: _saving,
                      child: ListView(
                        children: <Widget>[
                          if (_safeError != null)
                            Padding(
                              padding: const EdgeInsets.only(
                                bottom: KenaiSpacing.md,
                              ),
                              child: Text(
                                _safeError!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              ),
                            ),
                          _section(
                            title: 'Приложение',
                            children: <Widget>[
                              ListTile(
                                leading: const Icon(Icons.info_outline),
                                title: const Text('Версия'),
                                trailing: Text(
                                  '${widget.dependencies.buildInfo.version} '
                                  '(${widget.dependencies.buildInfo.buildNumber})',
                                  key: const Key('application-version'),
                                ),
                              ),
                              ListTile(
                                leading:
                                    const Icon(Icons.system_update_outlined),
                                title: const Text('Проверка обновлений'),
                                subtitle: Text(_updateMessage()),
                                trailing: FilledButton(
                                  key: const Key('check-for-updates'),
                                  onPressed:
                                      _checkingUpdates ? null : _checkUpdates,
                                  child: Text(
                                    _checkingUpdates
                                        ? 'Проверяем…'
                                        : 'Проверить',
                                  ),
                                ),
                              ),
                              _switch(
                                key: 'automatic-updates',
                                title: 'Автоматические обновления',
                                subtitle: _safeAutomaticUpdates
                                    ? 'Устанавливать только обновления с действительной подписью.'
                                    : 'Недоступно до подключения подписанного update-провайдера.',
                                value: _settings.autoUpdate,
                                enabled: _safeAutomaticUpdates,
                                onChanged: (bool value) => _save(
                                    _settings.copyWith(autoUpdate: value)),
                              ),
                            ],
                          ),
                          _section(
                            title: 'Внешний вид и язык',
                            children: <Widget>[
                              const ListTile(
                                key: Key('language-setting'),
                                leading: Icon(Icons.language),
                                title: Text('Язык'),
                                subtitle: Text(
                                  'Сейчас доступен русский. Другие локализации ещё не добавлены.',
                                ),
                                trailing: Text('Русский'),
                              ),
                              ListTile(
                                leading: const Icon(Icons.palette_outlined),
                                title: const Text('Тема'),
                                trailing: SizedBox(
                                  width: 190,
                                  child: DropdownButton<ThemePreference>(
                                    key: const Key('theme-setting'),
                                    value: _settings.theme,
                                    isExpanded: true,
                                    items: const <DropdownMenuItem<
                                        ThemePreference>>[
                                      DropdownMenuItem(
                                        value: ThemePreference.system,
                                        child: Text('Системная'),
                                      ),
                                      DropdownMenuItem(
                                        value: ThemePreference.light,
                                        child: Text('Светлая'),
                                      ),
                                      DropdownMenuItem(
                                        value: ThemePreference.dark,
                                        child: Text('Тёмная'),
                                      ),
                                    ],
                                    onChanged: (ThemePreference? value) {
                                      if (value != null) {
                                        unawaited(
                                          _save(
                                              _settings.copyWith(theme: value)),
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ),
                            ],
                          ),
                          _section(
                            title: 'Система',
                            children: <Widget>[
                              _switch(
                                key: 'app-launch-at-login',
                                title: 'Автозапуск',
                                subtitle: widget
                                        .dependencies
                                        .platformCapabilities
                                        .supportsLaunchAtLogin
                                    ? 'Запускать Kenai VPN при входе в Windows.'
                                    : 'Недоступно: системный адаптер автозапуска не подключён.',
                                value: _settings.launchAtLogin,
                                enabled: widget.dependencies
                                    .platformCapabilities.supportsLaunchAtLogin,
                                onChanged: (bool value) => _save(
                                  _settings.copyWith(launchAtLogin: value),
                                ),
                              ),
                              _switch(
                                key: 'tray-setting',
                                title: 'Системный трей',
                                subtitle: widget.dependencies
                                        .platformCapabilities.supportsTray
                                    ? 'Закрытие скрывает окно в область уведомлений. При сворачивании приложение остаётся на панели задач. VPN продолжает работать.'
                                    : 'Недоступно: tray-адаптер ещё не подключён.',
                                value: _settings.trayEnabled,
                                enabled: widget.dependencies
                                    .platformCapabilities.supportsTray,
                                onChanged: (bool value) => _save(
                                    _settings.copyWith(trayEnabled: value)),
                              ),
                            ],
                          ),
                          _section(
                            title: 'Конфиденциальность',
                            children: <Widget>[
                              _switch(
                                key: 'diagnostic-consent',
                                title: 'Согласие на диагностику',
                                subtitle:
                                    'Разрешение сохранено локально. Автоматическая отправка '
                                    'данных не выполняется.',
                                value: _settings.sendDiagnostics,
                                enabled: true,
                                onChanged: (bool value) => _save(
                                  _settings.copyWith(sendDiagnostics: value),
                                ),
                              ),
                              ListTile(
                                key: const Key('privacy-link'),
                                leading: const Icon(Icons.privacy_tip_outlined),
                                title:
                                    const Text('Политика конфиденциальности'),
                                subtitle: const Text(
                                  'PDF в приложении · базовая редакция от 18.09.2026',
                                ),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => Navigator.of(context).push<void>(
                                  MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const PrivacyPolicyScreen()),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );

  Widget _section({required String title, required List<Widget> children}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: KenaiSpacing.lg),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(KenaiSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(KenaiSpacing.md),
                  child: Text(title,
                      style: Theme.of(context).textTheme.titleLarge),
                ),
                ...children,
              ],
            ),
          ),
        ),
      );

  Widget _switch({
    required String key,
    required String title,
    required String subtitle,
    required bool value,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) =>
      Semantics(
        key: Key(key),
        enabled: enabled,
        child: SwitchListTile(
          title: Text(title),
          subtitle: Text(subtitle),
          value: enabled && value,
          onChanged: enabled ? onChanged : null,
        ),
      );

  Future<void> _load() async {
    try {
      final AppSettings settings =
          await widget.dependencies.settingsRepository.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _loading = false;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _safeError = 'Не удалось прочитать параметры приложения.';
        });
      }
    }
  }

  Future<void> _save(AppSettings settings) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _safeError = null;
    });
    try {
      await widget.dependencies.settingsRepository.save(settings);
      if (mounted) setState(() => _settings = settings);
    } on Object {
      if (mounted) {
        setState(() => _safeError = 'Не удалось сохранить параметры.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _checkUpdates() async {
    setState(() {
      _checkingUpdates = true;
      _safeError = null;
    });
    try {
      final UpdateCheckResult result =
          await widget.dependencies.updateProvider.checkForUpdates();
      if (mounted) setState(() => _updateResult = result);
    } on Object {
      if (mounted) {
        setState(() => _safeError = 'Не удалось проверить обновления.');
      }
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  String _updateMessage() {
    final UpdateCheckResult? result = _updateResult;
    if (result == null) {
      return widget.dependencies.updateProvider.isAvailable
          ? 'Проверка ещё не выполнялась.'
          : 'Подписанный update-провайдер не настроен.';
    }
    return switch (result.status) {
      UpdateStatus.unavailable => 'Проверка обновлений недоступна.',
      UpdateStatus.upToDate => 'Установлена актуальная версия.',
      UpdateStatus.available =>
        'Доступна версия ${result.latestVersion ?? 'новее текущей'}.',
      UpdateStatus.failed => 'Проверка обновлений завершилась ошибкой.',
    };
  }
}
