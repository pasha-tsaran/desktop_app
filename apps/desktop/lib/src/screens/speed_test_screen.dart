import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';

final class SpeedTestScreen extends StatefulWidget {
  const SpeedTestScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<SpeedTestScreen> createState() => _SpeedTestScreenState();
}

final class _SpeedTestScreenState extends State<SpeedTestScreen> {
  StreamSubscription<SpeedTestState>? _subscription;
  SpeedTestState _state = const SpeedTestState.idle();
  List<VpnServer> _servers = const <VpnServer>[];
  String? _serverId;
  ServerSort _sort = ServerSort.latency;
  bool _loadingServers = true;
  bool _refreshingPing = false;
  String? _safeError;

  bool get _isRunning => switch (_state.phase) {
        SpeedTestPhase.pinging ||
        SpeedTestPhase.downloading ||
        SpeedTestPhase.uploading =>
          true,
        _ => false,
      };

  @override
  void initState() {
    super.initState();
    _state = widget.dependencies.speedTestEngine.currentState;
    _subscription = widget.dependencies.speedTestEngine.states.listen(
      (SpeedTestState state) {
        if (mounted) setState(() => _state = state);
      },
    );
    unawaited(_loadServers());
  }

  @override
  void dispose() {
    _subscription?.cancel();
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Тест скорости',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: KenaiSpacing.xs),
                      const Text(
                        'Полный тест запускается только вручную и расходует трафик.',
                      ),
                    ],
                  ),
                ),
                if (widget.dependencies.speedTestEngine.isMock)
                  const Chip(label: Text('Mock-измерения')),
              ],
            ),
            const SizedBox(height: KenaiSpacing.lg),
            if (!widget.dependencies.speedTestEngine.isAvailable)
              Card(
                key: const Key('speed-test-unavailable'),
                child: Padding(
                  padding: const EdgeInsets.all(KenaiSpacing.lg),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: KenaiSpacing.md),
                      const Expanded(
                        child: Text(
                          'Production-сервис измерения скорости пока не настроен. '
                          'Фиктивные результаты в release-сборке отключены.',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            _buildControls(),
            const SizedBox(height: KenaiSpacing.lg),
            if (_safeError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: KenaiSpacing.md),
                child: Text(
                  _safeError!,
                  key: const Key('speed-test-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 3, child: _buildResults()),
                  const SizedBox(width: KenaiSpacing.lg),
                  Expanded(flex: 2, child: _buildServerRanking()),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildControls() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KenaiSpacing.md),
          child: Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const Key('speed-test-server'),
                  initialValue: _serverId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Сервер'),
                  items: _servers
                      .map(
                        (VpnServer server) => DropdownMenuItem<String>(
                          value: server.id,
                          child: Text(
                            '${server.countryName}, ${server.city}'
                            '${server.isTest ? ' · тестовый' : ''}',
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: _isRunning
                      ? null
                      : (String? value) => setState(() => _serverId = value),
                ),
              ),
              const SizedBox(width: KenaiSpacing.md),
              if (_isRunning)
                FilledButton.icon(
                  key: const Key('stop-speed-test'),
                  onPressed: _stop,
                  icon: const Icon(Icons.stop_circle_outlined),
                  label: const Text('Остановить'),
                )
              else
                FilledButton.icon(
                  key: const Key('start-speed-test'),
                  onPressed: widget.dependencies.speedTestEngine.isAvailable &&
                          _serverId != null
                      ? _confirmStart
                      : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Запустить полный тест'),
                ),
            ],
          ),
        ),
      );

  Widget _buildResults() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KenaiSpacing.xxl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(
                    _phaseLabel(_state.phase),
                    key: const Key('speed-test-phase'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const Spacer(),
                  if (_isRunning) const CircularProgressIndicator(),
                ],
              ),
              const SizedBox(height: KenaiSpacing.xxl),
              Wrap(
                spacing: KenaiSpacing.lg,
                runSpacing: KenaiSpacing.lg,
                children: <Widget>[
                  _Metric(
                    label: 'Средняя задержка',
                    value: _latency(_state.averageLatency),
                    icon: Icons.timer_outlined,
                  ),
                  _Metric(
                    label: 'Максимальная задержка',
                    value: _latency(_state.maximumLatency),
                    icon: Icons.av_timer,
                  ),
                  _Metric(
                    label: 'Download',
                    value: _rate(_state.downloadMbps),
                    icon: Icons.download,
                  ),
                  _Metric(
                    label: 'Upload',
                    value: _rate(_state.uploadMbps),
                    icon: Icons.upload,
                  ),
                ],
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.all(KenaiSpacing.md),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(KenaiRadii.control),
                ),
                child: Row(
                  children: <Widget>[
                    const Icon(Icons.data_usage_outlined),
                    const SizedBox(width: KenaiSpacing.sm),
                    Expanded(
                      child: Text(
                        _state.estimatedBytesUsed == 0
                            ? 'Ожидаемый расход полного теста: до 40 МБ.'
                            : 'Израсходовано примерно: '
                                '${(_state.estimatedBytesUsed / 1024 / 1024).toStringAsFixed(1)} МБ.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Widget _buildServerRanking() => Card(
        child: Padding(
          padding: const EdgeInsets.all(KenaiSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Ping серверов',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: KenaiSpacing.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: DropdownButton<ServerSort>(
                      key: const Key('speed-server-sort'),
                      value: _sort,
                      isExpanded: true,
                      items: const <DropdownMenuItem<ServerSort>>[
                        DropdownMenuItem(
                          value: ServerSort.latency,
                          child: Text('По задержке'),
                        ),
                        DropdownMenuItem(
                          value: ServerSort.name,
                          child: Text('По названию'),
                        ),
                        DropdownMenuItem(
                          value: ServerSort.recommended,
                          child: Text('Рекомендуемые'),
                        ),
                      ],
                      onChanged: (ServerSort? value) {
                        if (value == null) return;
                        setState(() => _sort = value);
                        unawaited(_loadServers());
                      },
                    ),
                  ),
                  IconButton(
                    key: const Key('refresh-server-ping'),
                    tooltip: 'Обновить ping',
                    onPressed: _refreshingPing ? null : _refreshPing,
                    icon: _refreshingPing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: _loadingServers
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        key: const Key('speed-server-list'),
                        itemCount: _servers.length,
                        itemBuilder: (BuildContext context, int index) {
                          final VpnServer server = _servers[index];
                          return ListTile(
                            dense: true,
                            title: Text(server.countryName),
                            subtitle: Text(server.city),
                            trailing: Text(
                              server.status.latency == null
                                  ? '—'
                                  : '${server.status.latency!.inMilliseconds} мс',
                            ),
                            onTap: _isRunning
                                ? null
                                : () => setState(() => _serverId = server.id),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );

  Future<void> _loadServers() async {
    try {
      final List<VpnServer> servers =
          await widget.dependencies.serverRepository.getServers(sort: _sort);
      final VpnServer? selected =
          await widget.dependencies.serverRepository.getSelectedServer();
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _serverId ??=
            selected?.id ?? (servers.isEmpty ? null : servers.first.id);
        _loadingServers = false;
      });
    } on Object {
      if (mounted) {
        setState(() {
          _loadingServers = false;
          _safeError = 'Не удалось получить список серверов.';
        });
      }
    }
  }

  Future<void> _refreshPing() async {
    setState(() => _refreshingPing = true);
    try {
      for (final VpnServer server
          in _servers.where((VpnServer item) => item.isAvailable)) {
        await widget.dependencies.serverRepository.ping(server.id);
      }
      await _loadServers();
    } on Object {
      if (mounted) setState(() => _safeError = 'Не удалось обновить ping.');
    } finally {
      if (mounted) setState(() => _refreshingPing = false);
    }
  }

  Future<void> _confirmStart() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Запустить полный тест?'),
            content: const Text(
              'Будут выполнены download и upload измерения. '
              'Тест может израсходовать до 40 МБ трафика.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                key: const Key('confirm-speed-test'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Запустить'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || _serverId == null) return;
    setState(() => _safeError = null);
    unawaited(
      widget.dependencies.speedTestEngine
          .start(serverId: _serverId!)
          .onError((Object _, StackTrace __) {
        if (mounted) {
          setState(() => _safeError = 'Не удалось выполнить тест скорости.');
        }
      }),
    );
  }

  Future<void> _stop() => widget.dependencies.speedTestEngine.stop();
}

final class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 220,
        child: Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(KenaiSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(icon),
                const SizedBox(height: KenaiSpacing.md),
                Text(value, style: Theme.of(context).textTheme.headlineSmall),
                Text(label),
              ],
            ),
          ),
        ),
      );
}

String _phaseLabel(SpeedTestPhase phase) => switch (phase) {
      SpeedTestPhase.idle => 'Готов к запуску',
      SpeedTestPhase.pinging => 'Измеряем задержку',
      SpeedTestPhase.downloading => 'Измеряем download',
      SpeedTestPhase.uploading => 'Измеряем upload',
      SpeedTestPhase.completed => 'Тест завершён',
      SpeedTestPhase.cancelled => 'Тест остановлен',
      SpeedTestPhase.failed => 'Тест не выполнен',
    };

String _latency(Duration? value) =>
    value == null ? '—' : '${value.inMilliseconds} мс';

String _rate(double? value) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} Мбит/с';
