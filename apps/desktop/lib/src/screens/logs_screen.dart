import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';

final class LogsScreen extends StatefulWidget {
  const LogsScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

final class _LogsScreenState extends State<LogsScreen> {
  final TextEditingController _searchController = TextEditingController();
  StreamSubscription<List<DiagnosticLogEntry>>? _subscription;
  List<DiagnosticLogEntry> _entries = const <DiagnosticLogEntry>[];
  DiagnosticSummary? _summary;
  DiagnosticCategory? _category;
  DiagnosticSeverity? _level;
  bool _loading = true;
  bool _exporting = false;
  String? _safeError;

  @override
  void initState() {
    super.initState();
    _subscription = widget.dependencies.diagnosticLogger.changes.listen(
      (_) => unawaited(_load()),
    );
    unawaited(_load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(KenaiSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _buildHeader(),
            const SizedBox(height: KenaiSpacing.lg),
            _buildFilters(),
            const SizedBox(height: KenaiSpacing.lg),
            if (_safeError != null) ...<Widget>[
              Text(
                _safeError!,
                key: const Key('diagnostics-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: KenaiSpacing.md),
            ],
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(flex: 3, child: _buildLogList()),
                  const SizedBox(width: KenaiSpacing.lg),
                  SizedBox(width: 280, child: _buildSummary()),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _buildHeader() => Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Логи и диагностика',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: KenaiSpacing.xs),
                const Text(
                  'Секреты удаляются локально до записи, показа и экспорта.',
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            key: const Key('copy-diagnostics'),
            onPressed: _entries.isEmpty ? null : _copyVisible,
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Копировать'),
          ),
          const SizedBox(width: KenaiSpacing.sm),
          OutlinedButton.icon(
            key: const Key('clear-diagnostics'),
            onPressed: _entries.isEmpty ? null : _confirmClear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Очистить'),
          ),
          const SizedBox(width: KenaiSpacing.sm),
          FilledButton.icon(
            key: const Key('export-diagnostics'),
            onPressed: _exporting ? null : _confirmExport,
            icon: _exporting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.archive_outlined),
            label: const Text('Экспорт ZIP'),
          ),
        ],
      );

  Widget _buildFilters() => Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              key: const Key('diagnostics-search'),
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Поиск по сообщению или коду',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (_) => unawaited(_load()),
            ),
          ),
          const SizedBox(width: KenaiSpacing.md),
          SizedBox(
            width: 220,
            child: DropdownButtonFormField<DiagnosticCategory?>(
              key: const Key('diagnostics-category'),
              isExpanded: true,
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Категория'),
              items: <DropdownMenuItem<DiagnosticCategory?>>[
                const DropdownMenuItem<DiagnosticCategory?>(
                  child: Text('Все категории'),
                ),
                ...DiagnosticCategory.values.map(
                  (DiagnosticCategory category) =>
                      DropdownMenuItem<DiagnosticCategory?>(
                    value: category,
                    child: Text(_categoryLabel(category)),
                  ),
                ),
              ],
              onChanged: (DiagnosticCategory? value) {
                setState(() => _category = value);
                unawaited(_load());
              },
            ),
          ),
          const SizedBox(width: KenaiSpacing.md),
          SizedBox(
            width: 180,
            child: DropdownButtonFormField<DiagnosticSeverity?>(
              key: const Key('diagnostics-level'),
              isExpanded: true,
              initialValue: _level,
              decoration: const InputDecoration(labelText: 'Уровень'),
              items: <DropdownMenuItem<DiagnosticSeverity?>>[
                const DropdownMenuItem<DiagnosticSeverity?>(
                  child: Text('Все уровни'),
                ),
                ...DiagnosticSeverity.values.map(
                  (DiagnosticSeverity level) =>
                      DropdownMenuItem<DiagnosticSeverity?>(
                    value: level,
                    child: Text(_levelLabel(level)),
                  ),
                ),
              ],
              onChanged: (DiagnosticSeverity? value) {
                setState(() => _level = value);
                unawaited(_load());
              },
            ),
          ),
        ],
      );

  Widget _buildLogList() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_entries.isEmpty) {
      return const Card(
        child: Center(
          child: Text(
            'По выбранным фильтрам событий нет.',
            key: Key('diagnostics-empty'),
          ),
        ),
      );
    }
    return Card(
      child: ListView.separated(
        key: const Key('diagnostics-list'),
        padding: const EdgeInsets.all(KenaiSpacing.md),
        itemCount: _entries.length,
        separatorBuilder: (_, __) => const Divider(height: KenaiSpacing.lg),
        itemBuilder: (BuildContext context, int index) {
          final DiagnosticLogEntry entry = _entries[index];
          return Semantics(
            label:
                '${_categoryLabel(entry.category)}, ${_levelLabel(entry.level)}',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _LevelMarker(level: entry.level),
                    const SizedBox(width: KenaiSpacing.sm),
                    Text(
                      _categoryLabel(entry.category),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const Spacer(),
                    Text(
                      _timeLabel(entry.occurredAt),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: KenaiSpacing.sm),
                SelectableText(
                  entry.message,
                  key: Key('diagnostic-message-$index'),
                ),
                const SizedBox(height: KenaiSpacing.xs),
                Text(
                  entry.code,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (entry.fields.isNotEmpty)
                  Text(
                    entry.fields.entries
                        .map((MapEntry<String, Object?> item) =>
                            '${item.key}: ${item.value}')
                        .join(' · '),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSummary() {
    final DiagnosticSummary? summary = _summary;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KenaiSpacing.lg),
        child: summary == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                key: const Key('diagnostic-summary'),
                children: <Widget>[
                  Text(
                    'Краткий отчёт',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: KenaiSpacing.md),
                  _SummaryRow(
                      label: 'Всего событий', value: summary.totalEvents),
                  _SummaryRow(
                      label: 'Предупреждения', value: summary.warningCount),
                  _SummaryRow(label: 'Ошибки', value: summary.errorCount),
                  const Divider(height: KenaiSpacing.xxl),
                  ...DiagnosticCategory.values.map(
                    (DiagnosticCategory category) => _SummaryRow(
                      label: _categoryLabel(category),
                      value: summary.categoryCounts[category] ?? 0,
                    ),
                  ),
                  const SizedBox(height: KenaiSpacing.lg),
                  Text(
                    'Отчёт остаётся на устройстве, пока вы сами не экспортируете его.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
      ),
    );
  }

  DiagnosticFilter get _filter => DiagnosticFilter(
        categories: _category == null
            ? const <DiagnosticCategory>{}
            : <DiagnosticCategory>{_category!},
        levels: _level == null
            ? const <DiagnosticSeverity>{}
            : <DiagnosticSeverity>{_level!},
        query: _searchController.text,
      );

  Future<void> _load() async {
    try {
      final List<DiagnosticLogEntry> entries =
          await widget.dependencies.diagnosticLogger.query(_filter);
      final DiagnosticSummary summary =
          await widget.dependencies.diagnosticLogger.summary();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _summary = summary;
        _loading = false;
        _safeError = null;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _safeError = 'Не удалось прочитать локальные журналы.';
      });
    }
  }

  Future<void> _copyVisible() async {
    final String text = _entries.map(_entryText).join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) _showMessage('Отфильтрованные записи скопированы.');
  }

  Future<void> _confirmClear() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Очистить все журналы?'),
            content: const Text('Это удалит локальные диагностические записи.'),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                key: const Key('confirm-clear-diagnostics'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Очистить'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await widget.dependencies.diagnosticLogger.clear();
    if (mounted) _showMessage('Журналы очищены.');
  }

  Future<void> _confirmExport() async {
    final DiagnosticPreview preview =
        await widget.dependencies.diagnosticExporter.preview();
    if (!mounted) return;
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Экспортировать диагностику?'),
            content: Text(
              'В ZIP войдут локальные журналы и краткий отчёт. '
              'Перед экспортом удаляются: ${preview.redactions.join(', ')}. '
              'Архив никуда не отправляется автоматически.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                key: const Key('confirm-export-diagnostics'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Сохранить ZIP'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _exporting = true);
    try {
      final DiagnosticArchive archive =
          await widget.dependencies.diagnosticExporter.createArchive();
      final DiagnosticArchiveLocation location =
          await widget.dependencies.diagnosticArchiveSaver.save(archive);
      if (mounted) _showMessage('Архив сохранён: ${location.path}');
    } on Object {
      if (mounted) {
        setState(
            () => _safeError = 'Не удалось сохранить диагностический архив.');
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String _entryText(DiagnosticLogEntry entry) =>
      '${entry.occurredAt.toUtc().toIso8601String()} '
      '[${entry.level.name}] [${entry.category.name}] '
      '${entry.code}: ${entry.message} ${entry.fields}';

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _LevelMarker extends StatelessWidget {
  const _LevelMarker({required this.level});

  final DiagnosticSeverity level;

  @override
  Widget build(BuildContext context) => Icon(
        switch (level) {
          DiagnosticSeverity.debug => Icons.bug_report_outlined,
          DiagnosticSeverity.info => Icons.info_outline,
          DiagnosticSeverity.warning => Icons.warning_amber_outlined,
          DiagnosticSeverity.error => Icons.error_outline,
        },
        size: 18,
        color: switch (level) {
          DiagnosticSeverity.debug => Theme.of(context).colorScheme.outline,
          DiagnosticSeverity.info => Theme.of(context).colorScheme.primary,
          DiagnosticSeverity.warning => KenaiTheme.warning,
          DiagnosticSeverity.error => KenaiTheme.danger,
        },
      );
}

final class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: KenaiSpacing.xs),
        child: Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text('$value', style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      );
}

String _categoryLabel(DiagnosticCategory category) => switch (category) {
      DiagnosticCategory.application => 'Приложение',
      DiagnosticCategory.wireGuard => 'WireGuard',
      DiagnosticCategory.amneziaWg => 'AmneziaWG',
      DiagnosticCategory.xray => 'Xray',
      DiagnosticCategory.systemService => 'Системная служба',
      DiagnosticCategory.network => 'Сеть',
    };

String _levelLabel(DiagnosticSeverity level) => switch (level) {
      DiagnosticSeverity.debug => 'Отладка',
      DiagnosticSeverity.info => 'Информация',
      DiagnosticSeverity.warning => 'Предупреждение',
      DiagnosticSeverity.error => 'Ошибка',
    };

String _timeLabel(DateTime value) {
  final DateTime local = value.toLocal();
  String digits(int number) => number.toString().padLeft(2, '0');
  return '${digits(local.day)}.${digits(local.month)}.${local.year} '
      '${digits(local.hour)}:${digits(local.minute)}:${digits(local.second)}';
}
