import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';
import '../infrastructure/wireguard_config_parser.dart';
import '../infrastructure/windows_profile_provisioner.dart';
import '../visual/connection_art.dart';
import '../visual/country_flag.dart';

final class ServersScreen extends StatefulWidget {
  const ServersScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<ServersScreen> createState() => _ServersScreenState();
}

final class _ServersScreenState extends State<ServersScreen> {
  late VpnConnectionState _connection;
  late VpnStatistics _statistics;
  late final StreamSubscription<VpnConnectionState> _subscription;
  Timer? _connectionTimer;
  List<VpnServer> _allServers = <VpnServer>[];
  List<VpnServer> _visibleServers = <VpnServer>[];
  bool _catalogLoading = true;
  bool _catalogFailed = false;
  int _catalogRequest = 0;
  VpnServer? _selected;
  VpnProtocol? _selectedProtocol;
  bool _protocolManuallySelected = false;
  ProtocolPreference _protocolPreference = ProtocolPreference.automatic;
  String _query = '';
  ServerSort _sort = ServerSort.recommended;
  bool _favoritesOnly = false;
  String? _countryCode;
  bool _pinging = false;
  bool _connecting = false;
  bool _cancelling = false;
  int _actionGeneration = 0;
  int _ipGeneration = 0;
  bool _ipInitialized = false;
  String? _publicIp;

  @override
  void initState() {
    super.initState();
    _connection = const VpnConnectionState.disconnected();
    _statistics = VpnStatistics(
      bytesReceived: 0,
      bytesSent: 0,
      measuredAt: DateTime.now(),
    );
    _subscription = widget.dependencies.vpnEngine.states.listen(
      _applyConnectionState,
    );
    unawaited(_loadInitialData());
  }

  @override
  void dispose() {
    _connectionTimer?.cancel();
    unawaited(_subscription.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth < 820) {
            return ListView(children: <Widget>[
              SizedBox(height: 600, child: _catalogPanel()),
              const SizedBox(height: 12),
              SizedBox(height: 620, child: _buildConnectionPanel()),
            ]);
          }
          return Row(children: <Widget>[
            Expanded(flex: 37, child: _catalogPanel()),
            const SizedBox(width: 12),
            Expanded(flex: 63, child: _buildConnectionPanel()),
          ]);
        }),
      );

  Widget _catalogPanel() => Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        decoration: _panelDecoration(context),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    Text('Серверы',
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    if (widget.dependencies.serverRepository.isMock)
                      _MockBadge(
                          hasTestServers: _allServers.any(_isTestServer)),
                  ]),
              Text('Выберите сервер и подключитесь',
                  style: TextStyle(
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: .62))),
              const SizedBox(height: 16),
              Expanded(child: _buildCatalog()),
            ]),
      );

  BoxDecoration _panelDecoration(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? const Color(0xFF0A1225) : const Color(0xFFDDE7F7),
      gradient: dark
          ? null
          : const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFFD9EEF7), Color(0xFFE0DDF6), Color(0xFFD6EBF4)],
            ),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: dark ? const Color(0xFF314472) : Colors.white),
    );
  }

  Widget _buildCatalog() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  key: const Key('server-search'),
                  decoration: const InputDecoration(
                    hintText: 'Страна, город или сервер',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (String query) {
                    _query = query;
                    _reloadServers();
                  },
                ),
              ),
              const SizedBox(width: KenaiSpacing.sm),
              PopupMenuButton<ServerSort>(
                key: const Key('server-sort'),
                tooltip: 'Сортировка: ${_sortLabel(_sort)}',
                initialValue: _sort,
                onSelected: (ServerSort value) {
                  _sort = value;
                  _reloadServers();
                },
                itemBuilder: (BuildContext context) => ServerSort.values
                    .map(
                      (ServerSort value) => PopupMenuItem<ServerSort>(
                        value: value,
                        child: Text(_sortLabel(value)),
                      ),
                    )
                    .toList(growable: false),
                icon: const Icon(Icons.sort),
              ),
            ],
          ),
          const SizedBox(height: KenaiSpacing.sm),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                FilterChip(
                  key: const Key('favorites-filter'),
                  selected: _favoritesOnly,
                  showCheckmark: false,
                  avatar: const Icon(Icons.star_outline, size: 18),
                  label: const Text('Избранное'),
                  onSelected: (bool selected) {
                    _favoritesOnly = selected;
                    _reloadServers();
                  },
                ),
                const SizedBox(width: KenaiSpacing.sm),
                PopupMenuButton<String>(
                  key: const Key('country-all'),
                  tooltip: 'Выбрать страну',
                  initialValue: _countryCode ?? '',
                  onSelected: (value) {
                    _countryCode = value.isEmpty ? null : value;
                    _reloadServers();
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    const PopupMenuItem(value: '', child: Text('Все страны')),
                    for (final country in <String, String>{
                      for (final server in _allServers)
                        server.countryCode: server.countryName,
                    }.entries)
                      PopupMenuItem(
                        key: Key('country-${country.key}'),
                        value: country.key,
                        child: Text(country.value),
                      ),
                  ],
                  child: Chip(
                    backgroundColor: Theme.of(context).chipTheme.selectedColor,
                    avatar:
                        const Icon(Icons.public, size: 18, color: Colors.white),
                    label: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          _allServers
                                  .where((s) => s.countryCode == _countryCode)
                                  .firstOrNull
                                  ?.countryName ??
                              'Все страны',
                          style: const TextStyle(color: Colors.white)),
                      const SizedBox(width: 4),
                      const Icon(Icons.expand_more,
                          size: 16, color: Colors.white),
                    ]),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: KenaiSpacing.sm),
          Expanded(
            child: _buildServerList(),
          ),
        ],
      );

  Widget _buildServerList() {
    if (_catalogLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_catalogFailed) {
      return const _CatalogMessage(
        icon: Icons.cloud_off_outlined,
        title: 'Не удалось загрузить серверы',
        message: 'Проверьте подключение и попробуйте ещё раз.',
      );
    }
    if (_visibleServers.isEmpty) {
      return const _CatalogMessage(
        icon: Icons.search_off,
        title: 'Ничего не найдено',
        message: 'Измените поиск или фильтры.',
      );
    }
    return ListView.separated(
      scrollCacheExtent: const ScrollCacheExtent.pixels(1200),
      itemCount: _visibleServers.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (BuildContext context, int index) =>
          _buildServerTile(_visibleServers[index]),
    );
  }

  Widget _buildServerTile(VpnServer server) {
    final _AvailabilityCopy availability = _availability(server.status);
    final bool selectionLocked = _connection.phase.isBusy ||
        _connection.phase == VpnConnectionPhase.connected;
    final bool selected = _selected?.id == server.id;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Material(
      color: selected
          ? (dark ? const Color(0xFF271762) : const Color(0xFFDCD0F5))
          : (dark ? const Color(0xFF10182B) : const Color(0xFFE3EAF9)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
            color: selected
                ? const Color(0xFF9A5FFF)
                : (dark ? const Color(0xFF202E50) : const Color(0xFFDCE5FF))),
      ),
      elevation: selected ? 6 : 0,
      shadowColor: KenaiTheme.accent.withValues(alpha: .4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: Key('server-${server.id}'),
        selected: selected,
        textColor: Theme.of(context).colorScheme.onSurface,
        selectedColor: Theme.of(context).colorScheme.onSurface,
        dense: false,
        minTileHeight: 62,
        visualDensity: VisualDensity.compact,
        contentPadding: const EdgeInsets.fromLTRB(8, 2, 2, 2),
        leading: CountryFlag(countryCode: server.countryCode, size: 42),
        title: Wrap(
          spacing: 4,
          runSpacing: 2,
          children: <Widget>[
            Text(server.countryName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (server.isRecommended) const _SmallBadge(label: 'Рекомендуемый'),
            if (server.isTest)
              const _SmallBadge(label: 'Тестовый', warning: true),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: KenaiSpacing.xs),
          child: Wrap(
            spacing: 4,
            children: <Widget>[
              Text('${server.city} · ${server.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
              if (availability.label != 'Не проверен') ...[
                Icon(Icons.circle, size: 8, color: availability.color),
                Text(availability.label),
              ],
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(_latencyLabel(server.status.latency),
                style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            IconButton(
              key: Key('favorite-${server.id}'),
              tooltip: server.isFavorite
                  ? 'Удалить из избранного'
                  : 'Добавить в избранное',
              onPressed: () => _toggleFavorite(server),
              icon: Icon(
                server.isFavorite ? Icons.star : Icons.star_outline,
                color: server.isFavorite ? KenaiTheme.warning : null,
              ),
            ),
          ],
        ),
        onTap: selectionLocked ? null : () => _selectServer(server),
      ),
    );
  }

  Widget _buildConnectionPanel() {
    final VpnServer? server = _selected;
    if (server == null) {
      return Container(
        key: const Key('connection-panel'),
        decoration: _panelDecoration(context),
        child: const _CatalogMessage(
          icon: Icons.dns_outlined,
          title: 'Выберите сервер',
          message: 'Сведения о подключении появятся здесь.',
        ),
      );
    }
    final bool connected = _connection.phase == VpnConnectionPhase.connected;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color ink = Theme.of(context).colorScheme.onSurface;
    final VpnProtocol protocol =
        _connection.protocol ?? _selectedProtocol ?? server.protocols.first;
    final bool engineSupportsProtocol =
        widget.dependencies.vpnEngine.supportedProtocols.contains(protocol);
    final bool busy = _connecting || _connection.phase.isBusy;
    final bool canConnect = !_cancelling &&
        (connected ||
            busy ||
            (server.canAttemptConnection && engineSupportsProtocol));
    final String buttonLabel = _cancelling
        ? 'Отменяем…'
        : connected
            ? 'Отключить'
            : busy
                ? 'Отменить подключение'
                : 'Подключиться';
    final _ConnectionCopy copy =
        _connectionCopy(_connection.phase, _connection.errorCode);
    return Container(
      key: const Key('connection-panel'),
      decoration: _panelDecoration(context),
      clipBehavior: Clip.antiAlias,
      child: Stack(children: <Widget>[
        Positioned.fill(
            child: ConnectionArt(
                dark: dark,
                connected: connected,
                countryCode: server.countryCode,
                countryName: server.countryName)),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: <Widget>[
            Row(children: <Widget>[
              CountryFlag(countryCode: server.countryCode, size: 60),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(server.countryName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: ink,
                          fontSize: 28,
                          fontWeight: FontWeight.w700)),
                  Text('${server.city}, ${server.countryName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: ink.withValues(alpha: .66))),
                  Wrap(spacing: 6, children: <Widget>[
                    if (server.isRecommended)
                      const _SmallBadge(label: 'Рекомендуемый'),
                    if (server.isTest)
                      const _SmallBadge(
                          label: 'Тестовый сервер', warning: true),
                    if (_availability(server.status).label != 'Не проверен')
                      _StatusBadge(copy: _availability(server.status)),
                  ]),
                ],
              )),
              OutlinedButton.icon(
                onPressed: () => _toggleFavorite(server),
                icon: Icon(server.isFavorite ? Icons.star : Icons.star_border),
                label: Text(
                    server.isFavorite ? 'В избранном' : 'Добавить в избранное'),
              ),
            ]),
            Expanded(child: LayoutBuilder(builder: (context, bounds) {
              final double sphere =
                  (bounds.maxHeight * .42).clamp(108.0, 205.0);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  ConnectionOrb(
                    dark: dark,
                    connected: connected,
                    size: sphere,
                    child: Tooltip(
                        message: buttonLabel,
                        child: Semantics(
                            label: buttonLabel,
                            child: FilledButton(
                              key: const Key('connect-button'),
                              onPressed: canConnect ? _toggleConnection : null,
                              style: FilledButton.styleFrom(
                                shape: const CircleBorder(),
                                backgroundColor: Colors.transparent,
                                disabledBackgroundColor: Colors.transparent,
                                elevation: 0,
                                padding: EdgeInsets.zero,
                              ),
                              child: busy || _cancelling
                                  ? const CircularProgressIndicator(
                                      color: Colors.white)
                                  : ConnectionGlyph(
                                      connected: connected, size: sphere * .43),
                            ))),
                  ),
                  const SizedBox(height: 13),
                  Text(copy.title,
                      key: const Key('connection-phase'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: ink,
                          fontSize: 23,
                          fontWeight: FontWeight.w700)),
                  Text(
                      _connection.killSwitchActive && !connected
                          ? 'Kill switch блокирует интернет. Подключитесь к VPN или выключите защиту в настройках.'
                          : copy.message,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: ink.withValues(alpha: .72), fontSize: 17)),
                  if (busy || _cancelling)
                    Text(buttonLabel, style: TextStyle(color: ink)),
                ],
              );
            })),
            Row(children: <Widget>[
              Expanded(
                  child: _referenceMetric(
                      const Key('connection-time'),
                      Icons.schedule,
                      'Время',
                      _durationLabel(_connectedDuration))),
              const SizedBox(width: 6),
              Expanded(
                  child: _referenceMetric(
                      const Key('traffic-received'),
                      Icons.south,
                      'Получено',
                      _bytesLabel(_statistics.bytesReceived))),
              const SizedBox(width: 6),
              Expanded(
                  child: _referenceMetric(
                      const Key('traffic-sent'),
                      Icons.north,
                      'Передано',
                      _bytesLabel(_statistics.bytesSent))),
              const SizedBox(width: 6),
              Expanded(
                  flex: 2,
                  child: Container(
                    height: 74,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: _tileDecoration(dark),
                    child: Row(children: <Widget>[
                      const Icon(Icons.link,
                          color: KenaiTheme.accent, size: 23),
                      const SizedBox(width: 6),
                      Expanded(
                          child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Протокол',
                              style: TextStyle(
                                  color: ink.withValues(alpha: .6),
                                  fontSize: 12)),
                          DropdownButtonHideUnderline(
                              child: DropdownButton<VpnProtocol>(
                            key: ValueKey<String>('protocol-${server.id}'),
                            isExpanded: true,
                            isDense: true,
                            iconSize: 18,
                            value: protocol,
                            items: server.protocols
                                .map((value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(_protocolLabel(value),
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 15)),
                                    ))
                                .toList(growable: false),
                            onChanged: connected || busy || _cancelling
                                ? null
                                : (value) {
                                    if (value != null)
                                      setState(() {
                                        _selectedProtocol = value;
                                        _protocolManuallySelected = true;
                                      });
                                  },
                          )),
                        ],
                      )),
                    ]),
                  )),
            ]),
            const SizedBox(height: 22),
            Row(children: <Widget>[
              Expanded(
                  flex: 3,
                  child: Container(
                    height: 74,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: _tileDecoration(dark),
                    child: Row(children: <Widget>[
                      const Icon(Icons.location_on, color: KenaiTheme.accent),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Текущий сервер',
                              style: TextStyle(
                                  color: ink.withValues(alpha: .6),
                                  fontSize: 12)),
                          Text(
                              connected
                                  ? '${server.city}, ${server.countryName}'
                                  : 'Не выбран',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: ink, fontWeight: FontWeight.w600)),
                        ],
                      )),
                      Container(
                          width: 1,
                          height: 34,
                          color: ink.withValues(alpha: .16)),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text('Ваш IP-адрес',
                              style: TextStyle(
                                  color: ink.withValues(alpha: .6),
                                  fontSize: 12)),
                          Text(_publicIp ?? '—',
                              key: const Key('public-ip'),
                              style: TextStyle(
                                  color: ink, fontWeight: FontWeight.w600)),
                        ],
                      )),
                    ]),
                  )),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                key: const Key('ping-button'),
                onPressed: _pinging ? null : _pingSelected,
                icon: const Icon(Icons.network_ping, size: 18),
                label: Text(_pinging
                    ? 'Проверяем…'
                    : _latencyLabel(server.status.latency)),
              ),
            ]),
            if (widget.dependencies.vpnEngine.isMock || !engineSupportsProtocol)
              Text(
                  widget.dependencies.vpnEngine.isMock
                      ? 'Mock VPN · системные настройки не изменяются'
                      : 'VPN-движок недоступен в этой сборке.',
                  style: Theme.of(context).textTheme.labelSmall),
          ]),
        ),
      ]),
    );
  }

  Widget _referenceMetric(Key key, IconData icon, String label, String value) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = Theme.of(context).colorScheme.onSurface;
    return Container(
      key: key,
      height: 74,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: _tileDecoration(dark),
      child: Row(children: <Widget>[
        Icon(icon, color: Theme.of(context).colorScheme.primary, size: 25),
        const SizedBox(width: 7),
        Expanded(
            child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: ink.withValues(alpha: .6), fontSize: 12)),
              Text(value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: ink, fontSize: 15, fontWeight: FontWeight.w700)),
            ])),
      ]),
    );
  }

  BoxDecoration _tileDecoration(bool dark) => BoxDecoration(
        color: dark ? const Color(0xDC10192D) : const Color(0xDDE2E6FA),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: dark ? const Color(0xFF344675) : Colors.white),
      );

  Duration get _connectedDuration {
    final DateTime? connectedAt = _connection.connectedAt;
    if (connectedAt == null) return Duration.zero;
    final Duration elapsed = DateTime.now().difference(connectedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  Future<void> _loadInitialData() async {
    try {
      final List<VpnServer> servers =
          await widget.dependencies.serverRepository.getServers();
      VpnServer? selected =
          await widget.dependencies.serverRepository.getSelectedServer();
      final AppSettings settings =
          await widget.dependencies.settingsRepository.load();
      final defaultServer =
          servers.where((s) => s.id == settings.defaultServerId).firstOrNull;
      if (defaultServer != null) {
        selected = defaultServer;
        await widget.dependencies.serverRepository
            .selectServer(defaultServer.id);
      }
      final VpnConnectionState state =
          await widget.dependencies.vpnEngine.status();
      if (state.phase == VpnConnectionPhase.connected &&
          state.serverId != null) {
        selected = servers
                .where((server) => server.id == state.serverId)
                .firstOrNull ??
            selected;
        if (selected != null) {
          await widget.dependencies.serverRepository.selectServer(selected.id);
        }
      }
      if (!mounted) return;
      setState(() {
        _allServers = servers;
        _visibleServers = servers;
        _catalogLoading = false;
        _catalogFailed = false;
        _selected = selected;
        _protocolPreference = settings.protocol;
        _selectedProtocol = selected == null
            ? null
            : _preferredProtocol(selected, settings.protocol);
      });
      _applyConnectionState(state);
    } on Object {
      if (!mounted) return;
      setState(() {
        _catalogLoading = false;
        _catalogFailed = true;
      });
      _showSafeMessage('Не удалось подготовить список серверов.');
    }
  }

  Future<void> _reloadServers() async {
    final int request = ++_catalogRequest;
    setState(() {
      _catalogLoading = true;
      _catalogFailed = false;
    });
    try {
      final List<VpnServer> servers =
          await widget.dependencies.serverRepository.getServers(
        query: _query,
        countryCode: _countryCode,
        sort: _sort,
        favoritesOnly: _favoritesOnly,
      );
      if (!mounted || request != _catalogRequest) return;
      setState(() {
        _visibleServers = servers;
        _catalogLoading = false;
      });
    } on Object {
      if (!mounted || request != _catalogRequest) return;
      setState(() {
        _catalogLoading = false;
        _catalogFailed = true;
      });
    }
  }

  Future<void> _selectServer(VpnServer server) async {
    try {
      await widget.dependencies.serverRepository.selectServer(server.id);
      if (!mounted) return;
      setState(() {
        _selected = server;
        _protocolManuallySelected = false;
        _selectedProtocol = _preferredProtocol(server, _protocolPreference);
      });
    } on Object {
      if (mounted) _showSafeMessage('Не удалось выбрать сервер.');
    }
  }

  Future<void> _toggleFavorite(VpnServer server) async {
    try {
      await widget.dependencies.serverRepository.toggleFavorite(server.id);
      final VpnServer? selected =
          await widget.dependencies.serverRepository.getSelectedServer();
      if (!mounted) return;
      setState(() => _selected = selected);
      await _reloadServers();
    } on Object {
      if (mounted) _showSafeMessage('Не удалось изменить избранное.');
    }
  }

  Future<void> _pingSelected() async {
    final VpnServer? server = _selected;
    if (server == null || _pinging) return;
    setState(() => _pinging = true);
    try {
      final Duration? latency =
          await widget.dependencies.serverRepository.ping(server.id);
      final VpnServer? selected =
          await widget.dependencies.serverRepository.getSelectedServer();
      if (!mounted) return;
      setState(() {
        _selected = selected;
        _pinging = false;
      });
      await _reloadServers();
      if (latency == null) {
        _showSafeMessage('Ping для этого сервера временно недоступен.');
      }
    } on Object {
      if (!mounted) return;
      setState(() => _pinging = false);
      _showSafeMessage('Не удалось проверить ping.');
    }
  }

  Future<void> _toggleConnection() async {
    final VpnServer? server = _selected;
    if (server == null || _cancelling) return;
    final stop = _connecting ||
        _connection.phase.isBusy ||
        _connection.phase == VpnConnectionPhase.connected;
    final action = ++_actionGeneration;
    setState(() {
      _cancelling = stop;
      _connecting = !stop;
    });
    try {
      final automation = widget.dependencies.automation;
      if (stop) {
        if (automation != null) {
          await automation.disconnect();
        } else {
          await widget.dependencies.vpnEngine.disconnect(
            operationId: 'disconnect-${DateTime.now().microsecondsSinceEpoch}',
          );
        }
        return;
      }
      if (automation != null) {
        final config = await widget.dependencies.settingsRepository.load();
        if (action != _actionGeneration) return;
        await automation.connect(server,
            protocol: config.protocol == ProtocolPreference.automatic &&
                    !_protocolManuallySelected
                ? null
                : _selectedProtocol);
        return;
      }
      if (_connection.phase == VpnConnectionPhase.connected) {
        await widget.dependencies.vpnEngine.disconnect(
          operationId: 'disconnect-${DateTime.now().microsecondsSinceEpoch}',
        );
        return;
      }
      if (!server.canAttemptConnection) {
        _showSafeMessage('Этот сервер сейчас недоступен.');
        return;
      }
      final VpnProtocol protocol = _selectedProtocol ?? server.protocols.first;
      if (!await widget.dependencies.accountRepository
          .ensureProtocolProfile(protocol, serverId: server.id)) {
        _showSafeMessage(
            'Профиль этого сервера пока недоступен. Попробуйте позже.');
        return;
      }
      if (action != _actionGeneration) return;
      await widget.dependencies.vpnEngine.connect(
        ConnectionRequest(
          operationId: 'connect-${DateTime.now().microsecondsSinceEpoch}',
          profile: VpnProfile(
            id: 'profile-${server.id}-${protocol.name}',
            deviceId: 'local-windows-device',
            serverId: server.id,
            protocol: protocol,
          ),
          // Enabled only after the dedicated leak-test gate.
          killSwitch: false,
        ),
      );
    } on Object catch (error) {
      final String errorCode = switch (error) {
        ProfileProvisioningException(:final code) => code,
        WireGuardConfigException(:final code) => code,
        AccountApiException(:final failure) =>
          'ACCOUNT_${failure.name.toUpperCase()}',
        StateError() => 'STATE_ERROR',
        _ => 'UNEXPECTED_ERROR',
      };
      unawaited(
        widget.dependencies.diagnosticLogger
            .log(
              DiagnosticLogInput(
                category: _selectedProtocol == VpnProtocol.amneziaWg
                    ? DiagnosticCategory.amneziaWg
                    : DiagnosticCategory.application,
                level: DiagnosticSeverity.error,
                code: 'CONNECT_$errorCode',
                message: 'VPN connection attempt failed before completion.',
                fields: <String, Object?>{
                  'server_id': server.id,
                  'protocol': _selectedProtocol?.name ?? 'automatic',
                },
              ),
            )
            .onError((Object _, StackTrace __) {}),
      );
      if (mounted && action == _actionGeneration) {
        _showSafeMessage('Операцию выполнить не удалось. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted && action == _actionGeneration) {
        setState(() {
          _connecting = false;
          _cancelling = false;
        });
      }
    }
  }

  void _applyConnectionState(VpnConnectionState state) {
    if (!mounted) return;
    final changed = !_ipInitialized ||
        _connection.phase != state.phase ||
        _connection.serverId != state.serverId;
    _ipInitialized = true;
    if (changed) {
      ++_ipGeneration;
      _publicIp = null;
      if (state.phase == VpnConnectionPhase.connected ||
          state.phase == VpnConnectionPhase.disconnected) {
        unawaited(_refreshPublicIp(_ipGeneration));
      }
    }
    setState(() => _connection = state);
    if (state.phase == VpnConnectionPhase.connected) {
      _startConnectionTimer();
      unawaited(_refreshStatistics());
    } else if (!state.phase.isBusy) {
      _stopConnectionTimer(resetStatistics: true);
    }
  }

  void _startConnectionTimer() {
    _connectionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      unawaited(_refreshStatistics());
    });
  }

  Future<void> _refreshPublicIp(int generation) async {
    String? address;
    try {
      address = await widget.dependencies.publicIpProbe.measure();
    } on Object {
      address = null;
    }
    if (mounted && generation == _ipGeneration) {
      setState(() => _publicIp = address);
    }
  }

  void _stopConnectionTimer({required bool resetStatistics}) {
    _connectionTimer?.cancel();
    _connectionTimer = null;
    if (resetStatistics) {
      _statistics = VpnStatistics(
        bytesReceived: 0,
        bytesSent: 0,
        measuredAt: DateTime.now(),
      );
    }
  }

  Future<void> _refreshStatistics() async {
    if (_connection.phase != VpnConnectionPhase.connected) return;
    final VpnStatistics statistics =
        await widget.dependencies.vpnEngine.statistics();
    if (mounted && _connection.phase == VpnConnectionPhase.connected) {
      setState(() => _statistics = statistics);
    }
  }

  void _showSafeMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _MockBadge extends StatelessWidget {
  const _MockBadge({required this.hasTestServers});

  final bool hasTestServers;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('mock-api-badge'),
        padding: const EdgeInsets.symmetric(
          horizontal: KenaiSpacing.md,
          vertical: KenaiSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: KenaiTheme.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(KenaiRadii.control),
        ),
        child: Text(
          hasTestServers ? 'Mock API · тестовые серверы' : 'Mock API',
        ),
      );
}

final class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, this.warning = false});

  final String label;
  final bool warning;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: (warning ? KenaiTheme.warning : KenaiTheme.accent).withValues(
            alpha: 0.14,
          ),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall),
      );
}

final class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.copy});

  final _AvailabilityCopy copy;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: copy.color),
          const SizedBox(width: KenaiSpacing.xs),
          Flexible(
              child: Text(copy.label,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      );
}

final class _CatalogMessage extends StatelessWidget {
  const _CatalogMessage({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(KenaiSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 40),
              const SizedBox(height: KenaiSpacing.sm),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: KenaiSpacing.xs),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
}

final class _ConnectionCopy {
  const _ConnectionCopy(this.title, this.message);

  final String title;
  final String message;
}

final class _AvailabilityCopy {
  const _AvailabilityCopy(this.label, this.color);

  final String label;
  final Color color;
}

_ConnectionCopy _connectionCopy(
  VpnConnectionPhase phase,
  String? errorCode,
) =>
    switch (phase) {
      VpnConnectionPhase.disconnected => const _ConnectionCopy(
          'VPN не подключён',
          'Подключение отсутствует',
        ),
      VpnConnectionPhase.validating => const _ConnectionCopy(
          'Проверяем профиль',
          'Это займёт несколько секунд.',
        ),
      VpnConnectionPhase.connecting => const _ConnectionCopy(
          'Подключаемся',
          'Настраиваем защищённое соединение.',
        ),
      VpnConnectionPhase.connected => const _ConnectionCopy(
          'VPN подключён',
          'Соединение защищено',
        ),
      VpnConnectionPhase.reconnecting => const _ConnectionCopy(
          'Восстанавливаем соединение',
          'Сеть изменилась, выполняется переподключение.',
        ),
      VpnConnectionPhase.disconnecting => const _ConnectionCopy(
          'Отключаем VPN',
          'Завершаем соединение безопасно.',
        ),
      VpnConnectionPhase.blockedBySubscription => const _ConnectionCopy(
          'Подключение приостановлено',
          'Продлите подписку, чтобы снова подключаться.',
        ),
      VpnConnectionPhase.noNetwork => const _ConnectionCopy(
          'Нет подключения к интернету',
          'Проверьте сеть — VPN попробует подключиться снова.',
        ),
      VpnConnectionPhase.serverUnavailable => const _ConnectionCopy(
          'Сервер временно недоступен',
          'Выберите другой сервер или повторите попытку позже.',
        ),
      VpnConnectionPhase.error when errorCode == 'TUNNEL_ROUTE_UNAVAILABLE' =>
        const _ConnectionCopy(
          'Туннель не направляет трафик',
          'Не удалось настроить маршруты VPN. Откройте диагностику.',
        ),
      VpnConnectionPhase.error => const _ConnectionCopy(
          'Не удалось подключиться',
          'Попробуйте ещё раз. Если ошибка повторится, откройте диагностику.',
        ),
    };

_AvailabilityCopy _availability(ServerStatus status) {
  if (status.operational == ServerOperationalStatus.maintenance) {
    return const _AvailabilityCopy('Техобслуживание', KenaiTheme.warning);
  }
  if (status.operational == ServerOperationalStatus.offline ||
      status.internetReachability == InternetReachability.unreachable) {
    return const _AvailabilityCopy('Недоступен', KenaiTheme.danger);
  }
  if (status.operational == ServerOperationalStatus.degraded) {
    return const _AvailabilityCopy('Нестабильно', KenaiTheme.warning);
  }
  if (status.isAvailable) {
    return const _AvailabilityCopy('Доступен', KenaiTheme.success);
  }
  return const _AvailabilityCopy('Не проверен', KenaiTheme.warning);
}

String _sortLabel(ServerSort sort) => switch (sort) {
      ServerSort.recommended => 'Сначала рекомендуемые',
      ServerSort.latency => 'По ping',
      ServerSort.name => 'По названию',
      ServerSort.country => 'По стране',
    };

String _protocolLabel(VpnProtocol protocol) => switch (protocol) {
      VpnProtocol.wireGuard => 'WireGuard',
      VpnProtocol.amneziaWg => 'AmneziaWG',
      VpnProtocol.vlessReality => 'VLESS + REALITY',
    };

VpnProtocol _preferredProtocol(
  VpnServer server,
  ProtocolPreference preference,
) {
  final VpnProtocol? requested = switch (preference) {
    ProtocolPreference.wireGuard => VpnProtocol.wireGuard,
    ProtocolPreference.amneziaWg => VpnProtocol.amneziaWg,
    ProtocolPreference.vlessReality => VpnProtocol.vlessReality,
    ProtocolPreference.automatic => null,
  };
  if (requested != null && server.protocols.contains(requested)) {
    return requested;
  }
  return server.protocols.first;
}

String _latencyLabel(Duration? latency) =>
    latency == null ? '—' : '${latency.inMilliseconds} ms';

String _durationLabel(Duration duration) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  final int hours = duration.inHours;
  final int minutes = duration.inMinutes.remainder(60);
  final int seconds = duration.inSeconds.remainder(60);
  return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
}

String _bytesLabel(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  final double kibibytes = bytes / 1024;
  if (kibibytes < 1024) return '${kibibytes.toStringAsFixed(1)} КБ';
  final double mebibytes = kibibytes / 1024;
  if (mebibytes < 1024) return '${mebibytes.toStringAsFixed(1)} МБ';
  return '${(mebibytes / 1024).toStringAsFixed(1)} ГБ';
}

bool _isTestServer(VpnServer server) => server.isTest;
