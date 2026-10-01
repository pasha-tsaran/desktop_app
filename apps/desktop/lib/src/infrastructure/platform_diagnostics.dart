import 'dart:convert';
import 'dart:io';

import 'package:kenai_core/kenai_core.dart';

final class JsonLinesDiagnosticLogStore implements DiagnosticLogStore {
  JsonLinesDiagnosticLogStore({required File file}) : _file = file;

  factory JsonLinesDiagnosticLogStore.forCurrentUser() {
    final String root =
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path;
    return JsonLinesDiagnosticLogStore(
      file: File(
        _join(<String>[root, 'Kenai VPN', 'logs', 'client.jsonl']),
      ),
    );
  }

  final File _file;
  Future<void> _pending = Future<void>.value();

  @override
  Future<void> append(DiagnosticLogEntry entry) {
    _pending = _pending.then((_) async {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        '${jsonEncode(_toJson(entry))}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    return _pending;
  }

  @override
  Future<void> clear() {
    _pending = _pending.then((_) async {
      if (await _file.exists()) await _file.writeAsString('', flush: true);
    });
    return _pending;
  }

  @override
  Future<List<DiagnosticLogEntry>> readAll() async {
    await _pending;
    if (!await _file.exists()) return const <DiagnosticLogEntry>[];
    final List<DiagnosticLogEntry> entries = <DiagnosticLogEntry>[];
    final List<String> lines = await _file.readAsLines();
    for (final String line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final Object? decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic>) {
          entries.add(_fromJson(decoded));
        }
      } on Object {
        // A partial/corrupt line is ignored; no raw content is surfaced to UI.
      }
    }
    return List<DiagnosticLogEntry>.unmodifiable(entries);
  }

  static Map<String, Object?> _toJson(DiagnosticLogEntry entry) =>
      <String, Object?>{
        'occurred_at': entry.occurredAt.toUtc().toIso8601String(),
        'category': entry.category.name,
        'level': entry.level.name,
        'code': entry.code,
        'message': entry.message,
        'fields': entry.fields,
      };

  static DiagnosticLogEntry _fromJson(Map<String, dynamic> json) =>
      DiagnosticLogEntry(
        occurredAt: DateTime.parse(json['occurred_at']! as String).toUtc(),
        category: DiagnosticCategory.values.byName(json['category']! as String),
        level: DiagnosticSeverity.values.byName(json['level']! as String),
        code: json['code']! as String,
        message: json['message']! as String,
        fields: Map<String, Object?>.unmodifiable(
          (json['fields']! as Map).cast<String, Object?>(),
        ),
      );
}

final class DownloadsDiagnosticArchiveSaver implements DiagnosticArchiveSaver {
  DownloadsDiagnosticArchiveSaver({Directory? directory})
      : _directory = directory;

  final Directory? _directory;

  @override
  Future<DiagnosticArchiveLocation> save(DiagnosticArchive archive) async {
    if (!RegExp(r'^kenai-diagnostics-[A-Za-z0-9_-]+\.zip$')
        .hasMatch(archive.fileName)) {
      throw const FormatException('Unsafe diagnostic archive name');
    }
    final Directory directory = _directory ?? _defaultDownloadsDirectory();
    await directory.create(recursive: true);
    final File file = File(_join(<String>[directory.path, archive.fileName]));
    await file.writeAsBytes(archive.bytes, flush: true);
    return DiagnosticArchiveLocation(path: file.path);
  }

  static Directory _defaultDownloadsDirectory() {
    final String? profile = Platform.environment['USERPROFILE'];
    if (profile != null && profile.trim().isNotEmpty) {
      return Directory(_join(<String>[profile, 'Downloads']));
    }
    return Directory(_join(<String>[Directory.systemTemp.path, 'Kenai VPN']));
  }
}

String _join(List<String> segments) => segments.join(Platform.pathSeparator);
