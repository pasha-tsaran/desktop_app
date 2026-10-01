import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../domain/models.dart';
import '../ports/ports.dart';

final class SecretRedactor {
  static const String replacement = '[REDACTED]';

  String redactText(String input) {
    if (_looksLikeCompleteVpnConfiguration(input)) {
      return '[REDACTED VPN CONFIGURATION]';
    }

    String output = input;
    output = output.replaceAll(
      RegExp(r'vless://[^\s]+', caseSensitive: false),
      replacement,
    );
    output = output.replaceAllMapped(
      RegExp(
        r'(^|[^A-Za-z0-9+/])([A-Za-z0-9+/]{43}=)(?=$|[^A-Za-z0-9+/=])',
        multiLine: true,
      ),
      (Match match) => '${match.group(1)}$replacement',
    );
    output = output.replaceAll(
      RegExp(
        r'\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b',
        caseSensitive: false,
      ),
      replacement,
    );
    output = output.replaceAll(
      RegExp(r'(?<!\d)(?:\d[ -]?){11}\d(?!\d)'),
      replacement,
    );
    output = output.replaceAll(
      RegExp(r'\bBearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer $replacement',
    );
    output = output.replaceAllMapped(
      RegExp(
        r'\b(authorization|proxy-authorization|cookie|set-cookie)\s*:\s*([^\r\n]+)',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}: $replacement',
    );
    output = output.replaceAllMapped(
      RegExp(
        r'\b(activation[_ -]?key|private[_ -]?key|access[_ -]?token|refresh[_ -]?token|token|password|passwd|secret|uuid|vpn[_ -]?config(?:uration)?)\s*[:=]\s*([^\s,;]+)',
        caseSensitive: false,
      ),
      (Match match) => '${match.group(1)}=$replacement',
    );
    return output;
  }

  Object? redactValue(Object? value, {String? fieldName}) {
    if (fieldName != null && _isSensitiveField(fieldName)) return replacement;
    if (value is String) return redactText(value);
    if (value is Map) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          entry.key.toString(): redactValue(
            entry.value,
            fieldName: entry.key.toString(),
          ),
      };
    }
    if (value is Iterable) {
      return value.map((Object? item) => redactValue(item)).toList();
    }
    return value;
  }

  DiagnosticLogEntry redactEntry(DiagnosticLogEntry entry) => entry.copyWith(
        code: redactText(entry.code),
        message: redactText(entry.message),
        fields: Map<String, Object?>.unmodifiable(
          (redactValue(entry.fields) as Map).cast<String, Object?>(),
        ),
      );

  bool _looksLikeCompleteVpnConfiguration(String input) {
    final String normalized = input.toLowerCase();
    return (normalized.contains('[interface]') &&
            normalized.contains('[peer]')) ||
        (normalized.contains('privatekey') &&
            normalized.contains('endpoint') &&
            normalized.contains('allowedips')) ||
        (normalized.contains('"outbounds"') &&
            normalized.contains('"realitysettings"'));
  }

  bool _isSensitiveField(String fieldName) {
    final String normalized =
        fieldName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return normalized == 'authorization' ||
        normalized == 'proxyauthorization' ||
        normalized == 'cookie' ||
        normalized == 'setcookie' ||
        normalized.contains('activationkey') ||
        normalized.contains('privatekey') ||
        normalized.contains('accesstoken') ||
        normalized.contains('refreshtoken') ||
        normalized == 'token' ||
        normalized.contains('password') ||
        normalized == 'passwd' ||
        normalized.contains('secret') ||
        normalized == 'uuid' ||
        normalized.contains('vpnconfig') ||
        normalized.contains('credential') ||
        normalized.contains('realityprivate');
  }
}

final class RedactingDiagnostics
    implements DiagnosticLogger, DiagnosticExporter {
  RedactingDiagnostics({
    required DiagnosticLogStore store,
    SecretRedactor? redactor,
    DateTime Function()? clock,
  })  : _store = store,
        _redactor = redactor ?? SecretRedactor(),
        _clock = clock ?? DateTime.now;

  final DiagnosticLogStore _store;
  final SecretRedactor _redactor;
  final DateTime Function() _clock;
  final StreamController<List<DiagnosticLogEntry>> _changes =
      StreamController<List<DiagnosticLogEntry>>.broadcast();

  @override
  Stream<List<DiagnosticLogEntry>> get changes => _changes.stream;

  @override
  Future<void> log(DiagnosticLogInput input) async {
    final DiagnosticLogEntry sanitized = _redactor.redactEntry(
      DiagnosticLogEntry(
        occurredAt: _clock().toUtc(),
        category: input.category,
        level: input.level,
        code: input.code,
        message: input.message,
        fields: input.fields,
      ),
    );
    await _store.append(sanitized);
    _changes.add(await query());
  }

  @override
  Future<List<DiagnosticLogEntry>> query([
    DiagnosticFilter filter = const DiagnosticFilter(),
  ]) async {
    final String query = filter.query.trim().toLowerCase();
    final List<DiagnosticLogEntry> entries = (await _store.readAll())
        .map(_redactor.redactEntry)
        .where(
          (DiagnosticLogEntry entry) =>
              (filter.categories.isEmpty ||
                  filter.categories.contains(entry.category)) &&
              (filter.levels.isEmpty || filter.levels.contains(entry.level)) &&
              (query.isEmpty ||
                  entry.message.toLowerCase().contains(query) ||
                  entry.code.toLowerCase().contains(query)),
        )
        .toList(growable: false)
      ..sort(
        (DiagnosticLogEntry left, DiagnosticLogEntry right) =>
            right.occurredAt.compareTo(left.occurredAt),
      );
    return List<DiagnosticLogEntry>.unmodifiable(entries);
  }

  @override
  Future<void> clear() async {
    await _store.clear();
    _changes.add(const <DiagnosticLogEntry>[]);
  }

  @override
  Future<DiagnosticSummary> summary() async {
    final List<DiagnosticLogEntry> entries = await query();
    return DiagnosticSummary(
      generatedAt: _clock().toUtc(),
      totalEvents: entries.length,
      warningCount: entries
          .where((DiagnosticLogEntry entry) =>
              entry.level == DiagnosticSeverity.warning)
          .length,
      errorCount: entries
          .where((DiagnosticLogEntry entry) =>
              entry.level == DiagnosticSeverity.error)
          .length,
      categoryCounts: <DiagnosticCategory, int>{
        for (final DiagnosticCategory category in DiagnosticCategory.values)
          category: entries
              .where((DiagnosticLogEntry entry) => entry.category == category)
              .length,
      },
    );
  }

  @override
  Future<DiagnosticPreview> preview() async => DiagnosticPreview(
        categories: DiagnosticCategory.values
            .map((DiagnosticCategory category) => category.name)
            .toList(growable: false),
        redactions: const <String>[
          'activation keys',
          'private keys and VPN configurations',
          'UUIDs and tokens',
          'cookies, passwords and sensitive HTTP headers',
        ],
      );

  @override
  Future<DiagnosticArchive> createArchive() async {
    // Redact again at the export boundary even though stored entries are safe.
    final List<DiagnosticLogEntry> entries = (await _store.readAll())
        .map(_redactor.redactEntry)
        .toList(growable: false);
    final DiagnosticSummary report = await summary();
    final String logs = entries.map(_entryJson).join('\n');
    final String reportJson = jsonEncode(<String, Object?>{
      'generated_at': report.generatedAt.toIso8601String(),
      'total_events': report.totalEvents,
      'warnings': report.warningCount,
      'errors': report.errorCount,
      'categories': <String, int>{
        for (final MapEntry<DiagnosticCategory, int> entry
            in report.categoryCounts.entries)
          entry.key.name: entry.value,
      },
      'privacy': 'Secrets are removed locally before archive creation.',
    });
    final List<int> bytes = _ZipEncoder.encode(<String, List<int>>{
      'logs.jsonl': utf8.encode(logs),
      'report.json': utf8.encode(reportJson),
    });
    final DateTime now = _clock().toUtc();
    final String stamp = now
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-')
        .replaceAll('Z', '');
    return DiagnosticArchive(
      fileName: 'kenai-diagnostics-$stamp.zip',
      bytes: List<int>.unmodifiable(bytes),
    );
  }

  Future<void> dispose() => _changes.close();

  String _entryJson(DiagnosticLogEntry entry) => jsonEncode(<String, Object?>{
        'occurred_at': entry.occurredAt.toUtc().toIso8601String(),
        'category': entry.category.name,
        'level': entry.level.name,
        'code': entry.code,
        'message': entry.message,
        'fields': entry.fields,
      });
}

final class _ZipEncoder {
  static List<int> encode(Map<String, List<int>> files) {
    final BytesBuilder local = BytesBuilder(copy: false);
    final BytesBuilder central = BytesBuilder(copy: false);
    int offset = 0;

    for (final MapEntry<String, List<int>> file in files.entries) {
      final List<int> name = utf8.encode(file.key);
      final List<int> data = file.value;
      final int crc = _crc32(data);
      final BytesBuilder header = BytesBuilder(copy: false)
        ..add(_u32(0x04034b50))
        ..add(_u16(20))
        ..add(_u16(0x0800))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0x21))
        ..add(_u32(crc))
        ..add(_u32(data.length))
        ..add(_u32(data.length))
        ..add(_u16(name.length))
        ..add(_u16(0))
        ..add(name);
      final List<int> localHeader = header.takeBytes();
      local
        ..add(localHeader)
        ..add(data);

      central
        ..add(_u32(0x02014b50))
        ..add(_u16(20))
        ..add(_u16(20))
        ..add(_u16(0x0800))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0x21))
        ..add(_u32(crc))
        ..add(_u32(data.length))
        ..add(_u32(data.length))
        ..add(_u16(name.length))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u16(0))
        ..add(_u32(0))
        ..add(_u32(offset))
        ..add(name);
      offset += localHeader.length + data.length;
    }

    final List<int> centralBytes = central.takeBytes();
    final BytesBuilder result = BytesBuilder(copy: false)
      ..add(local.takeBytes())
      ..add(centralBytes)
      ..add(_u32(0x06054b50))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(files.length))
      ..add(_u16(files.length))
      ..add(_u32(centralBytes.length))
      ..add(_u32(offset))
      ..add(_u16(0));
    return result.takeBytes();
  }

  static List<int> _u16(int value) => <int>[
        value & 0xff,
        (value >> 8) & 0xff,
      ];

  static List<int> _u32(int value) => <int>[
        value & 0xff,
        (value >> 8) & 0xff,
        (value >> 16) & 0xff,
        (value >> 24) & 0xff,
      ];

  static int _crc32(List<int> data) {
    int crc = 0xffffffff;
    for (final int byte in data) {
      crc ^= byte;
      for (int bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    return (crc ^ 0xffffffff) & 0xffffffff;
  }
}
