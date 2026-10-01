import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:kenai_core/kenai_core.dart';

final class PlatformSecureStorage implements SecureStorage {
  PlatformSecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<void> clear() => _storage.deleteAll();
}
