import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';

final class VpnSettingsScreen extends StatefulWidget {
  const VpnSettingsScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<VpnSettingsScreen> createState() => _VpnSettingsScreenState();
}

final class _VpnSettingsScreenState extends State<VpnSettingsScreen> {
  AppSettings _settings = const AppSettings.defaults();
  List<VpnServer> _servers = <VpnServer>[];
  bool _loading = true;
  bool _saving = false;
  late final StreamSubscription<AppSettings> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.dependencies.settingsRepository.changes.listen(
      (AppSettings settings) {
        if (mounted) setState(() => _settings = settings);
      },
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
    super.dispose();
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
                    'Настройки VPN',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                if (widget.dependencies.vpnEngine.isMock)
                  const _MockAdaptersBadge(),
              ],
            ),
            const SizedBox(height: KenaiSpacing.sm),
            const Text(
              'Настройки подключения и поведения приложения в Windows.',
            ),
            const SizedBox(height: KenaiSpacing.lg),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : AbsorbPointer(
                      absorbing: _saving,
                      child: ListView(
                        children: <Widget>[
                          _buildConnectionPreferences(),
                          const SizedBox(height: KenaiSpacing.md),
                          _buildSystemFeatures(),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      );

  Widget _buildConnectionPreferences() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KenaiSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                'Подключение',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: KenaiSpacing.lg),
              DropdownButtonFormField<ProtocolPreference>(
                key: const Key('protocol-preference'),
                initialValue: _protocolPreferenceAvailable(_settings.protocol)
                    ? _settings.protocol
                    : ProtocolPreference.automatic,
                decoration: const InputDecoration(
                  labelText: 'Протокол',
                  helperText:
                      'Автоматически: VLESS, затем AmneziaWG, если подключение не удалось.',
                ),
                items: ProtocolPreference.values
                    .where(_protocolPreferenceAvailable)
                    .map(
                      (ProtocolPreference value) =>
                          DropdownMenuItem<ProtocolPreference>(
                        value: value,
                        child: Text(_protocolPreferenceLabel(value)),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (ProtocolPreference? value) {
                  if (value != null) {
                    _save(_settings.copyWith(protocol: value));
                  }
                },
              ),
              const SizedBox(height: KenaiSpacing.lg),
              DropdownButtonFormField<String>(
                key: const Key('default-server'),
                initialValue: _defaultServerValue,
                decoration: const InputDecoration(
                  labelText: 'Сервер по умолчанию',
                ),
                items: _servers
                    .map(
                      (VpnServer server) => DropdownMenuItem<String>(
                        value: server.id,
                        child: Text('${server.countryName} · ${server.city}'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (String? value) {
                  if (value != null) unawaited(_selectDefaultServer(value));
                },
              ),
            ],
          ),
        ),
      );

  Widget _buildSystemFeatures() {
    final bool killSwitch = _adapterSupport(
      (VpnAdapterCapabilities value) => value.supportsKillSwitch,
    );
    final bool dns = _adapterSupport(
      (VpnAdapterCapabilities value) => value.supportsDns,
    );
    final bool networkReconnect = _adapterSupport(
      (VpnAdapterCapabilities value) => value.supportsNetworkChangeReconnect,
    );
    final bool sleepRecovery = _adapterSupport(
      (VpnAdapterCapabilities value) => value.supportsSleepRecovery,
    );
    final ClientPlatformCapabilities platform =
        widget.dependencies.platformCapabilities;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: KenaiSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: KenaiSpacing.xl,
                vertical: KenaiSpacing.sm,
              ),
              child: Text(
                'Системные функции',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            _CapabilitySwitch(
              key: const Key('kill-switch-setting'),
              title: 'Kill switch',
              description:
                  'Блокирует интернет вне VPN, в том числе после ручного отключения. Для обычного интернета выключите эту настройку.',
              value: _settings.killSwitch,
              supported: killSwitch,
              onChanged: (bool value) =>
                  _save(_settings.copyWith(killSwitch: value)),
            ),
            ListTile(
              key: const Key('dns-setting'),
              enabled: dns,
              title: const Text('DNS'),
              subtitle: Text(
                dns
                    ? 'Выбор режима DNS поддерживается адаптером.'
                    : 'DNS задаётся профилем VPN-сервера.',
              ),
              trailing: DropdownButton<DnsPreference>(
                value: _settings.dns,
                onChanged: dns
                    ? (DnsPreference? value) {
                        if (value != null) {
                          _save(_settings.copyWith(dns: value));
                        }
                      }
                    : null,
                items: DnsPreference.values
                    .map(
                      (DnsPreference value) => DropdownMenuItem<DnsPreference>(
                        value: value,
                        child: Text(_dnsLabel(value)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
            ListTile(
              key: const Key('auto-connect-setting'),
              enabled: platform.supportsAutoConnect,
              title: const Text('Автоматическое подключение'),
              subtitle: Text(
                platform.supportsAutoConnect
                    ? 'Подключаться к VPN при запуске приложения. Само приложение запускается отдельной настройкой ниже.'
                    : _unavailableCopy,
              ),
              trailing: DropdownButton<AutoConnectMode>(
                value: _settings.autoConnect,
                onChanged: platform.supportsAutoConnect
                    ? (AutoConnectMode? value) {
                        if (value != null) {
                          _save(_settings.copyWith(autoConnect: value));
                        }
                      }
                    : null,
                items: AutoConnectMode.values
                    .map(
                      (AutoConnectMode value) =>
                          DropdownMenuItem<AutoConnectMode>(
                        value: value,
                        child: Text(_autoConnectLabel(value)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
            _CapabilitySwitch(
              key: const Key('network-reconnect-setting'),
              title: 'Переподключение после смены сети',
              value: _settings.reconnectOnNetworkChange,
              supported: networkReconnect,
              onChanged: (bool value) => _save(
                _settings.copyWith(reconnectOnNetworkChange: value),
              ),
            ),
            ListTile(
              key: const Key('sleep-behavior-setting'),
              enabled: sleepRecovery,
              title: const Text('После сна'),
              subtitle: Text(sleepRecovery
                  ? 'Политика восстановления VPN.'
                  : _unavailableCopy),
              trailing: DropdownButton<SleepBehavior>(
                value: _settings.sleepBehavior,
                onChanged: sleepRecovery
                    ? (SleepBehavior? value) {
                        if (value != null) {
                          _save(_settings.copyWith(sleepBehavior: value));
                        }
                      }
                    : null,
                items: SleepBehavior.values
                    .map(
                      (SleepBehavior value) => DropdownMenuItem<SleepBehavior>(
                        value: value,
                        child: Text(_sleepLabel(value)),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
            _CapabilitySwitch(
              key: const Key('launch-at-login-setting'),
              title: 'Автозапуск приложения',
              description:
                  'Открывать Kenai VPN при входе в Windows. Подключение к VPN настраивается отдельно.',
              value: _settings.launchAtLogin,
              supported: platform.supportsLaunchAtLogin,
              onChanged: (bool value) =>
                  _save(_settings.copyWith(launchAtLogin: value)),
            ),
            _CapabilitySwitch(
              key: const Key('minimize-after-connect-setting'),
              title: 'Сворачивать после подключения',
              value: _settings.minimizeAfterConnect,
              supported: platform.supportsMinimizeAfterConnect,
              onChanged: (bool value) =>
                  _save(_settings.copyWith(minimizeAfterConnect: value)),
            ),
          ],
        ),
      ),
    );
  }

  String? get _defaultServerValue =>
      _servers.any((VpnServer server) => server.id == _settings.defaultServerId)
          ? _settings.defaultServerId
          : _servers.firstOrNull?.id;

  bool _protocolPreferenceAvailable(ProtocolPreference preference) {
    if (preference == ProtocolPreference.automatic) return true;
    final protocol = _protocolForPreference(preference);
    return widget.dependencies.vpnEngine.supportedProtocols
            .contains(protocol) &&
        _servers.any((server) => server.protocols.contains(protocol));
  }

  bool _adapterSupport(bool Function(VpnAdapterCapabilities) test) {
    final Iterable<VpnProtocol> protocols = _settings.protocol ==
            ProtocolPreference.automatic
        ? widget.dependencies.vpnEngine.supportedProtocols.where((protocol) =>
            _servers.any((server) => server.protocols.contains(protocol)))
        : <VpnProtocol>[_protocolForPreference(_settings.protocol)];
    return protocols.isNotEmpty &&
        protocols.every(
          (VpnProtocol protocol) =>
              test(widget.dependencies.vpnEngine.capabilitiesFor(protocol)),
        );
  }

  Future<void> _load() async {
    try {
      final AppSettings settings =
          await widget.dependencies.settingsRepository.load();
      final List<VpnServer> servers =
          await widget.dependencies.serverRepository.getServers();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _servers = servers;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() => _loading = false);
      _showMessage('Не удалось загрузить настройки.');
    }
  }

  Future<void> _save(AppSettings settings) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.dependencies.settingsRepository.save(settings);
    } on Object {
      if (mounted) _showMessage('Не удалось сохранить настройку.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _selectDefaultServer(String serverId) async {
    try {
      await widget.dependencies.serverRepository.selectServer(serverId);
      await _save(_settings.copyWith(defaultServerId: serverId));
    } on Object {
      if (mounted) _showMessage('Не удалось выбрать сервер по умолчанию.');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

const String _unavailableCopy =
    'Недоступно: текущая конфигурация VPN не поддерживает эту функцию.';

final class _CapabilitySwitch extends StatelessWidget {
  const _CapabilitySwitch({
    required this.title,
    required this.value,
    required this.supported,
    required this.onChanged,
    this.description,
    super.key,
  });

  final String title;
  final bool value;
  final bool supported;
  final ValueChanged<bool> onChanged;
  final String? description;

  @override
  Widget build(BuildContext context) => SwitchListTile(
        value: value,
        onChanged: supported ? onChanged : null,
        title: Text(title),
        subtitle: Text(supported
            ? description ?? 'Применяется автоматически.'
            : _unavailableCopy),
      );
}

final class _MockAdaptersBadge extends StatelessWidget {
  const _MockAdaptersBadge();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('mock-adapters-badge'),
        padding: const EdgeInsets.symmetric(
          horizontal: KenaiSpacing.md,
          vertical: KenaiSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: KenaiTheme.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(KenaiRadii.control),
        ),
        child: const Text('Mock VPN-адаптеры'),
      );
}

VpnProtocol _protocolForPreference(ProtocolPreference preference) =>
    switch (preference) {
      ProtocolPreference.wireGuard => VpnProtocol.wireGuard,
      ProtocolPreference.amneziaWg => VpnProtocol.amneziaWg,
      ProtocolPreference.vlessReality => VpnProtocol.vlessReality,
      ProtocolPreference.automatic => VpnProtocol.wireGuard,
    };

String _protocolPreferenceLabel(ProtocolPreference value) => switch (value) {
      ProtocolPreference.automatic => 'Автоматически',
      ProtocolPreference.wireGuard => 'WireGuard',
      ProtocolPreference.amneziaWg => 'AmneziaWG',
      ProtocolPreference.vlessReality => 'VLESS + REALITY',
    };

String _dnsLabel(DnsPreference value) => switch (value) {
      DnsPreference.automatic => 'Автоматически',
      DnsPreference.system => 'Системный DNS',
    };

String _autoConnectLabel(AutoConnectMode value) => switch (value) {
      AutoConnectMode.disabled => 'Не подключаться',
      AutoConnectMode.recommendedServer => 'Рекомендуемый сервер',
      AutoConnectMode.selectedServer => 'Сервер по умолчанию',
    };

String _sleepLabel(SleepBehavior value) => switch (value) {
      SleepBehavior.reconnect => 'Переподключиться',
      SleepBehavior.disconnect => 'Оставить отключённым',
    };
