import 'dart:convert';

import '../domain/models.dart';
import '../ports/ports.dart';

/// Stable non-secret storage key names shared with platform VPN adapters.
abstract final class SecureAccountStorageKeys {
  static const String activationKey = 'account.activation_key';
  static const String session = 'account.session';
  static const String wireGuard = 'vpn.wireguard';
  static const String amneziaWg = 'vpn.amneziawg';
  static const String vless = 'vpn.vless';
  static const String profileHandle = 'vpn.profile_handle';
  static const String amneziaWgProfileHandle = 'vpn.amneziawg_profile_handle';
  static const String vlessProfileHandle = 'vpn.vless_profile_handle';
  static const String netherlandsVlessProfileHandle =
      'vpn.vless_profile_handle.netherlands-1';
  static const String netherlandsVless = 'vpn.vless.netherlands-1';
  static const String netherlandsAmneziaWgProfileHandle =
      'vpn.amneziawg_profile_handle.netherlands-1';
  static const String netherlandsAmneziaWg = 'vpn.amneziawg.netherlands-1';
}

final class SecureAccountRepository implements AccountRepository {
  SecureAccountRepository({
    required ActivationApiClient apiClient,
    required SecureStorage secureStorage,
    VpnProfileProvisioner? profileProvisioner,
  })  : _apiClient = apiClient,
        _secureStorage = secureStorage,
        _profileProvisioner = profileProvisioner;

  static const String _activationKey = SecureAccountStorageKeys.activationKey;
  static const String _session = SecureAccountStorageKeys.session;
  static const String _wireGuard = SecureAccountStorageKeys.wireGuard;
  static const String _amneziaWg = SecureAccountStorageKeys.amneziaWg;
  static const String _vless = SecureAccountStorageKeys.vless;
  static const String _profileHandle = SecureAccountStorageKeys.profileHandle;
  static const String _amneziaWgProfileHandle =
      SecureAccountStorageKeys.amneziaWgProfileHandle;
  static const String _vlessProfileHandle =
      SecureAccountStorageKeys.vlessProfileHandle;

  final ActivationApiClient _apiClient;
  final SecureStorage _secureStorage;
  final VpnProfileProvisioner? _profileProvisioner;
  Future<bool>? _amneziaWgRefresh;
  Future<bool>? _netherlandsVlessRefresh;
  Future<bool>? _netherlandsAmneziaWgRefresh;

  @override
  bool get isMock => _apiClient.isMock;

  @override
  Future<AccountSession> activate(ActivationKey activationKey) async {
    final ActivationResult result = await _apiClient.activate(activationKey);
    final AccountSession session = AccountSession(
      account: result.account,
      subscription: result.subscription,
      activationKeyMask: activationKey.masked,
    );
    String? provisionedHandle;
    String? provisionedAmneziaWgHandle;
    String? provisionedVlessHandle;
    try {
      final String? previousNetherlandsHandle = await _secureStorage.read(
        SecureAccountStorageKeys.netherlandsVlessProfileHandle,
      );
      if (previousNetherlandsHandle != null && _profileProvisioner != null) {
        await _profileProvisioner.deleteProfile(previousNetherlandsHandle);
      }
      await _secureStorage.delete(
        SecureAccountStorageKeys.netherlandsVlessProfileHandle,
      );
      await _secureStorage.delete(SecureAccountStorageKeys.netherlandsVless);
      final String? previousNetherlandsAwgHandle = await _secureStorage.read(
        SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
      );
      if (previousNetherlandsAwgHandle != null && _profileProvisioner != null) {
        await _profileProvisioner.deleteProfile(previousNetherlandsAwgHandle);
      }
      await _secureStorage.delete(
        SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
      );
      await _secureStorage.delete(
        SecureAccountStorageKeys.netherlandsAmneziaWg,
      );
      await _secureStorage.write(
        key: _activationKey,
        value: activationKey.value,
      );
      final String? wireGuard = result.vpnCredentials[VpnProtocol.wireGuard];
      if (_profileProvisioner != null && wireGuard != null) {
        provisionedHandle = await _profileProvisioner.provisionWireGuard(
          wireGuard,
        );
        await _secureStorage.write(
          key: _profileHandle,
          value: provisionedHandle,
        );
        await _secureStorage.delete(_wireGuard);
      } else {
        await _writeCredential(_wireGuard, wireGuard);
        await _secureStorage.delete(_profileHandle);
      }
      await _writeCredential(
        _amneziaWg,
        _profileProvisioner == null
            ? result.vpnCredentials[VpnProtocol.amneziaWg]
            : null,
      );
      final String? amneziaWg = result.vpnCredentials[VpnProtocol.amneziaWg];
      if (_profileProvisioner != null && amneziaWg != null) {
        try {
          provisionedAmneziaWgHandle =
              await _profileProvisioner.provisionAmneziaWg(amneziaWg);
          await _secureStorage.write(
            key: _amneziaWgProfileHandle,
            value: provisionedAmneziaWgHandle,
          );
        } on Object {
          if (provisionedAmneziaWgHandle != null) {
            try {
              await _profileProvisioner.deleteProfile(
                provisionedAmneziaWgHandle,
              );
            } on Object {
              // The VLESS activation must remain usable if AWG cleanup fails.
            }
          }
          provisionedAmneziaWgHandle = null;
          await _secureStorage.delete(_amneziaWgProfileHandle);
        }
      } else {
        await _secureStorage.delete(_amneziaWgProfileHandle);
      }
      final String? vless = result.vpnCredentials[VpnProtocol.vlessReality];
      await _writeCredential(
        _vless,
        _profileProvisioner == null ? vless : null,
      );
      if (_profileProvisioner != null && vless != null) {
        provisionedVlessHandle =
            await _profileProvisioner.provisionVlessReality(vless);
        await _secureStorage.write(
          key: _vlessProfileHandle,
          value: provisionedVlessHandle,
        );
      } else {
        await _secureStorage.delete(_vlessProfileHandle);
      }
      await _secureStorage.write(key: _session, value: _encode(session));
      return session;
    } on Object {
      if (provisionedHandle != null) {
        try {
          await _profileProvisioner?.deleteProfile(provisionedHandle);
        } on Object {
          // Preserve the original activation/storage failure. The service uses
          // opaque encrypted files; a later activation replaces stale state.
        }
      }
      if (provisionedAmneziaWgHandle != null) {
        try {
          await _profileProvisioner?.deleteProfile(provisionedAmneziaWgHandle);
        } on Object {
          /* preserve original error */
        }
      }
      if (provisionedVlessHandle != null) {
        try {
          await _profileProvisioner?.deleteProfile(provisionedVlessHandle);
        } on Object {
          // Preserve the original activation/storage failure.
        }
      }
      await _clearAccountData();
      rethrow;
    }
  }

  @override
  Future<AccountSession?> restoreSession() async {
    final String? encoded = await _secureStorage.read(_session);
    if (encoded == null) return null;
    try {
      return _decode(encoded);
    } on Object {
      await _clearAccountData();
      return null;
    }
  }

  @override
  Future<bool> ensureProtocolProfile(
    VpnProtocol protocol, {
    String serverId = 'armenia-1',
  }) async {
    if (serverId == 'netherlands-1') {
      if (protocol == VpnProtocol.vlessReality) {
        final Future<bool> refresh =
            _netherlandsVlessRefresh ??= _fetchNetherlandsVless();
        try {
          return await refresh;
        } finally {
          if (identical(_netherlandsVlessRefresh, refresh)) {
            _netherlandsVlessRefresh = null;
          }
        }
      }
      if (protocol == VpnProtocol.amneziaWg) {
        final Future<bool> refresh =
            _netherlandsAmneziaWgRefresh ??= _fetchNetherlandsAmneziaWg();
        try {
          return await refresh;
        } finally {
          if (identical(_netherlandsAmneziaWgRefresh, refresh)) {
            _netherlandsAmneziaWgRefresh = null;
          }
        }
      }
      return false;
    }
    if (serverId != 'armenia-1' && !_apiClient.isMock) return false;
    if (protocol != VpnProtocol.amneziaWg) return true;
    final Future<bool> refresh = _amneziaWgRefresh ??= _fetchMissingAmneziaWg();
    try {
      return await refresh;
    } finally {
      if (identical(_amneziaWgRefresh, refresh)) _amneziaWgRefresh = null;
    }
  }

  Future<bool> _fetchNetherlandsAmneziaWg() async {
    final String credentialKey = _profileProvisioner == null
        ? SecureAccountStorageKeys.netherlandsAmneziaWg
        : SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle;
    if (await _secureStorage.read(credentialKey) != null) return true;
    final String? storedKey = await _secureStorage.read(_activationKey);
    final String? encodedSession = await _secureStorage.read(_session);
    if (storedKey == null || encodedSession == null) {
      throw StateError('No active account');
    }
    final AccountSession current = _decode(encodedSession);
    final ActivationResult result = await _apiClient.activate(
      ActivationKey.parse(storedKey),
    );
    if (result.account.id != current.account.id ||
        result.subscription.status != SubscriptionStatus.active) {
      throw StateError('Account mismatch');
    }
    final String? configuration =
        result.locationAmneziaWgCredentials['netherlands-1'];
    if (configuration == null || configuration.isEmpty) return false;
    if (_profileProvisioner == null) {
      await _secureStorage.write(key: credentialKey, value: configuration);
      return true;
    }
    final String handle = await _profileProvisioner.provisionAmneziaWg(
      configuration,
    );
    try {
      await _secureStorage.write(key: credentialKey, value: handle);
    } on Object {
      await _profileProvisioner.deleteProfile(handle);
      rethrow;
    }
    return true;
  }

  Future<bool> _fetchNetherlandsVless() async {
    final String credentialKey = _profileProvisioner == null
        ? SecureAccountStorageKeys.netherlandsVless
        : SecureAccountStorageKeys.netherlandsVlessProfileHandle;
    if (await _secureStorage.read(credentialKey) != null) return true;
    final String? storedKey = await _secureStorage.read(_activationKey);
    final String? encodedSession = await _secureStorage.read(_session);
    if (storedKey == null || encodedSession == null) {
      throw StateError('No active account');
    }
    final AccountSession current = _decode(encodedSession);
    final ActivationResult result = await _apiClient.activate(
      ActivationKey.parse(storedKey),
    );
    if (result.account.id != current.account.id ||
        result.subscription.status != SubscriptionStatus.active) {
      throw StateError('Account mismatch');
    }
    final String? configuration =
        result.locationVlessCredentials['netherlands-1'];
    if (configuration == null || configuration.isEmpty) return false;
    if (_profileProvisioner == null) {
      await _secureStorage.write(key: credentialKey, value: configuration);
      return true;
    }
    final String handle = await _profileProvisioner.provisionVlessReality(
      configuration,
    );
    try {
      await _secureStorage.write(key: credentialKey, value: handle);
    } on Object {
      await _profileProvisioner.deleteProfile(handle);
      rethrow;
    }
    return true;
  }

  Future<bool> _fetchMissingAmneziaWg() async {
    final String credentialKey =
        _profileProvisioner == null ? _amneziaWg : _amneziaWgProfileHandle;
    if (await _secureStorage.read(credentialKey) != null) return true;
    final String? storedKey = await _secureStorage.read(_activationKey);
    final String? encodedSession = await _secureStorage.read(_session);
    if (storedKey == null || encodedSession == null) {
      throw StateError('No active account');
    }
    final AccountSession current = _decode(encodedSession);
    final ActivationResult result = await _apiClient.activate(
      ActivationKey.parse(storedKey),
    );
    if (result.account.id != current.account.id ||
        result.subscription.status != SubscriptionStatus.active) {
      throw StateError('Account mismatch');
    }
    final String? configuration = result.vpnCredentials[VpnProtocol.amneziaWg];
    if (configuration == null || configuration.isEmpty) {
      return false;
    }
    if (_profileProvisioner == null) {
      await _secureStorage.write(key: _amneziaWg, value: configuration);
      return true;
    }
    final String handle = await _profileProvisioner.provisionAmneziaWg(
      configuration,
    );
    try {
      await _secureStorage.write(key: _amneziaWgProfileHandle, value: handle);
    } on Object {
      await _profileProvisioner.deleteProfile(handle);
      rethrow;
    }
    return true;
  }

  @override
  Future<String?> revealActivationKey() => _secureStorage.read(_activationKey);

  @override
  Future<void> signOut() async {
    final String? profileHandle = await _secureStorage.read(_profileHandle);
    if (profileHandle != null && _profileProvisioner != null) {
      await _profileProvisioner.deleteProfile(profileHandle);
    }
    final String? amneziaWgHandle = await _secureStorage.read(
      _amneziaWgProfileHandle,
    );
    if (amneziaWgHandle != null && _profileProvisioner != null) {
      await _profileProvisioner.deleteProfile(amneziaWgHandle);
    }
    final String? vlessHandle = await _secureStorage.read(_vlessProfileHandle);
    if (vlessHandle != null && _profileProvisioner != null) {
      await _profileProvisioner.deleteProfile(vlessHandle);
    }
    final String? netherlandsHandle = await _secureStorage.read(
      SecureAccountStorageKeys.netherlandsVlessProfileHandle,
    );
    if (netherlandsHandle != null && _profileProvisioner != null) {
      await _profileProvisioner.deleteProfile(netherlandsHandle);
    }
    final String? netherlandsAwgHandle = await _secureStorage.read(
      SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
    );
    if (netherlandsAwgHandle != null && _profileProvisioner != null) {
      await _profileProvisioner.deleteProfile(netherlandsAwgHandle);
    }
    await _clearAccountData();
  }

  Future<void> _clearAccountData() async {
    for (final String key in <String>[
      _activationKey,
      _session,
      _wireGuard,
      _amneziaWg,
      _vless,
      _profileHandle,
      _amneziaWgProfileHandle,
      _vlessProfileHandle,
      SecureAccountStorageKeys.netherlandsVless,
      SecureAccountStorageKeys.netherlandsVlessProfileHandle,
      SecureAccountStorageKeys.netherlandsAmneziaWg,
      SecureAccountStorageKeys.netherlandsAmneziaWgProfileHandle,
    ]) {
      await _secureStorage.delete(key);
    }
  }

  Future<void> _writeCredential(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secureStorage.delete(key);
      return;
    }
    await _secureStorage.write(key: key, value: value);
  }

  static String _encode(AccountSession session) => jsonEncode(<String, Object?>{
        'account': <String, Object?>{
          'id': session.account.id,
          'email': session.account.email,
          'telegram_username': session.account.telegramUsername,
          'phone_number': session.account.phoneNumber,
        },
        'subscription': <String, Object?>{
          'status': session.subscription.status.name,
          'plan_name': session.subscription.planName,
          'expires_at': session.subscription.expiresAt?.toIso8601String(),
          'device_limit': session.subscription.deviceLimit,
          'last_verified_at':
              session.subscription.lastVerifiedAt?.toIso8601String(),
        },
        'activation_key_mask': session.activationKeyMask,
      });

  static AccountSession _decode(String encoded) {
    final Map<String, Object?> data =
        jsonDecode(encoded) as Map<String, Object?>;
    final Map<String, Object?> account =
        data['account']! as Map<String, Object?>;
    final Map<String, Object?> subscription =
        data['subscription']! as Map<String, Object?>;
    return AccountSession(
      account: Account(
        id: account['id']! as String,
        email: account['email'] as String?,
        telegramUsername: account['telegram_username'] as String?,
        phoneNumber: account['phone_number'] as String?,
      ),
      subscription: Subscription(
        status: SubscriptionStatus.values.byName(
          subscription['status']! as String,
        ),
        planName: subscription['plan_name']! as String,
        expiresAt: _date(subscription['expires_at']),
        deviceLimit: subscription['device_limit']! as int,
        lastVerifiedAt: _date(subscription['last_verified_at']),
      ),
      activationKeyMask: data['activation_key_mask']! as String,
    );
  }

  static DateTime? _date(Object? value) =>
      value is String ? DateTime.parse(value) : null;
}
