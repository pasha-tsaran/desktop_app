import 'package:kenai_core/kenai_core.dart';
import 'package:test/test.dart';

final class _RecordingProvisioner implements VpnProfileProvisioner {
  final List<String> deleted = <String>[];

  @override
  Future<String> provisionWireGuard(String configuration) async =>
      'wg-00112233445566778899aabbccddeeff';

  @override
  Future<String> provisionAmneziaWg(String configuration) async =>
      'awg-00112233445566778899aabbccddeeff';

  @override
  Future<String> provisionVlessReality(String configuration) async =>
      'xray-00112233445566778899aabbccddeeff';

  @override
  Future<void> deleteProfile(String profileId) async {
    deleted.add(profileId);
  }
}

final class _FailingAwgProvisioner implements VpnProfileProvisioner {
  @override
  Future<String> provisionWireGuard(String configuration) async => 'wg-handle';

  @override
  Future<String> provisionAmneziaWg(String configuration) async =>
      throw StateError('AWG import failed');

  @override
  Future<String> provisionVlessReality(String configuration) async =>
      'xray-handle';

  @override
  Future<void> deleteProfile(String profileId) async {}
}

void main() {
  group('account activation', () {
    test('validates and masks a 12-digit activation key', () {
      final ActivationKey key = ActivationKey.parse(_testActivationKey());

      expect(key.masked, '•••• •••• 9012');
      expect(key.toString(), key.masked);
      expect(() => ActivationKey.parse('123'), throwsFormatException);
      expect(() => ActivationKey.parse('12345678901x'), throwsFormatException);
    });

    test('stores session, key and profiles, then clears all on sign out',
        () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
      );

      final AccountSession activated = await repository.activate(
        ActivationKey.parse(_testActivationKey()),
      );

      expect(activated.subscription.status, SubscriptionStatus.active);
      expect(activated.activationKeyMask, '•••• •••• 9012');
      expect(await repository.restoreSession(), isNotNull);
      expect(await repository.revealActivationKey(), _testActivationKey());
      expect(await storage.read('vpn.wireguard'), isNotNull);
      expect(await storage.read('vpn.amneziawg'), isNotNull);
      expect(await storage.read('vpn.vless'), isNotNull);
      await storage.write(key: 'app.settings', value: 'preserve');

      await repository.signOut();

      expect(await repository.restoreSession(), isNull);
      expect(await repository.revealActivationKey(), isNull);
      expect(await storage.read('vpn.wireguard'), isNull);
      expect(await storage.read('app.settings'), 'preserve');
    });

    test('models active, expired and suspended subscription states', () async {
      final Map<MockActivationScenario, SubscriptionStatus> cases =
          <MockActivationScenario, SubscriptionStatus>{
        MockActivationScenario.active: SubscriptionStatus.active,
        MockActivationScenario.expired: SubscriptionStatus.expired,
        MockActivationScenario.suspended: SubscriptionStatus.suspended,
      };

      for (final MapEntry<MockActivationScenario, SubscriptionStatus> entry
          in cases.entries) {
        final ActivationResult result = await MockActivationApiClient(
          scenario: entry.key,
        ).activate(ActivationKey.parse(_testActivationKey()));
        expect(result.subscription.status, entry.value);
      }
    });

    test('typed API failures never persist an activation key', () async {
      for (final MockActivationScenario scenario in <MockActivationScenario>[
        MockActivationScenario.invalidKey,
        MockActivationScenario.noNetwork,
        MockActivationScenario.rateLimited,
        MockActivationScenario.serverError,
      ]) {
        final InMemorySecureStorage storage = InMemorySecureStorage();
        final SecureAccountRepository repository = SecureAccountRepository(
          apiClient: MockActivationApiClient(scenario: scenario),
          secureStorage: storage,
        );

        await expectLater(
          repository.activate(ActivationKey.parse(_testActivationKey())),
          throwsA(isA<AccountApiException>()),
        );
        expect(await repository.revealActivationKey(), isNull);
      }
    });

    test('reactivation removes credentials omitted by the server', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      await storage.write(key: 'vpn.amneziawg', value: 'obsolete-awg');
      await storage.write(key: 'vpn.vless', value: 'obsolete-vless');
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: const _WireGuardOnlyActivationClient(),
        secureStorage: storage,
      );

      await repository.activate(ActivationKey.parse(_testActivationKey()));

      expect(await storage.read('vpn.wireguard'), 'wireguard-profile');
      expect(await storage.read('vpn.amneziawg'), isNull);
      expect(await storage.read('vpn.vless'), isNull);
    });

    test(
        'production-style provisioning stores only a handle and deletes it on sign out',
        () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final _RecordingProvisioner provisioner = _RecordingProvisioner();
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
        profileProvisioner: provisioner,
      );

      await repository.activate(ActivationKey.parse(_testActivationKey()));

      expect(await storage.read('vpn.wireguard'), isNull);
      expect(
        await storage.read('vpn.profile_handle'),
        'wg-00112233445566778899aabbccddeeff',
      );
      expect(
        await storage.read('vpn.amneziawg_profile_handle'),
        'awg-00112233445566778899aabbccddeeff',
      );
      expect(
        await storage.read('vpn.vless_profile_handle'),
        'xray-00112233445566778899aabbccddeeff',
      );

      await repository.signOut();

      expect(provisioner.deleted, <String>[
        'wg-00112233445566778899aabbccddeeff',
        'awg-00112233445566778899aabbccddeeff',
        'xray-00112233445566778899aabbccddeeff',
      ]);
      expect(await storage.read('vpn.profile_handle'), isNull);
      expect(await storage.read('vpn.amneziawg_profile_handle'), isNull);
      expect(await storage.read('vpn.vless_profile_handle'), isNull);
    });

    test('an existing install fetches only its missing AmneziaWG profile',
        () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final _RecordingProvisioner provisioner = _RecordingProvisioner();
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
        profileProvisioner: provisioner,
      );
      await repository.activate(ActivationKey.parse(_testActivationKey()));
      final String? vlessHandle =
          await storage.read('vpn.vless_profile_handle');
      await storage.delete('vpn.amneziawg_profile_handle');

      await repository.ensureProtocolProfile(VpnProtocol.amneziaWg);
      await repository.ensureProtocolProfile(VpnProtocol.amneziaWg);

      expect(await storage.read('vpn.amneziawg_profile_handle'),
          'awg-00112233445566778899aabbccddeeff');
      expect(await storage.read('vpn.vless_profile_handle'), vlessHandle);
      expect(await repository.revealActivationKey(), _testActivationKey());
    });

    test('Netherlands profile is fetched separately from Armenia', () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final _RecordingProvisioner provisioner = _RecordingProvisioner();
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: _TwoLocationActivationClient(),
        secureStorage: storage,
        profileProvisioner: provisioner,
      );
      await repository.activate(ActivationKey.parse(_testActivationKey()));
      expect(
          await storage
              .read(SecureAccountStorageKeys.netherlandsVlessProfileHandle),
          isNull);

      expect(
          await repository.ensureProtocolProfile(VpnProtocol.vlessReality,
              serverId: 'netherlands-1'),
          isTrue);
      expect(
          await storage
              .read(SecureAccountStorageKeys.netherlandsVlessProfileHandle),
          'xray-00112233445566778899aabbccddeeff');
      expect(
          await repository.ensureProtocolProfile(VpnProtocol.amneziaWg,
              serverId: 'netherlands-1'),
          isFalse);
      await repository.signOut();
      expect(
          await storage
              .read(SecureAccountStorageKeys.netherlandsVlessProfileHandle),
          isNull);
    });

    test('AWG import failure does not remove a working VLESS activation',
        () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final SecureAccountRepository repository = SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: storage,
        profileProvisioner: _FailingAwgProvisioner(),
      );

      final AccountSession session =
          await repository.activate(ActivationKey.parse(_testActivationKey()));

      expect(session.subscription.status, SubscriptionStatus.active);
      expect(await storage.read('vpn.vless_profile_handle'), 'xray-handle');
      expect(await storage.read('vpn.amneziawg_profile_handle'), isNull);
      expect(await repository.revealActivationKey(), _testActivationKey());
    });
  });

  group('MockVpnEngine', () {
    test('routes each protocol through its dedicated adapter', () async {
      final MockWireGuardAdapter wireGuard = MockWireGuardAdapter();
      final MockAmneziaWgAdapter amnezia = MockAmneziaWgAdapter();
      final MockXrayRealityAdapter xray = MockXrayRealityAdapter();
      final List<MockProtocolAdapter> adapters = <MockProtocolAdapter>[
        wireGuard,
        amnezia,
        xray,
      ];

      for (final MockProtocolAdapter target in adapters) {
        final MockVpnEngine engine = MockVpnEngine(
          transitionDelay: Duration.zero,
          adapters: adapters,
        );
        await engine.connect(
          ConnectionRequest(
            operationId: 'connect-${target.protocol.name}',
            profile: VpnProfile(
              id: 'profile-${target.protocol.name}',
              deviceId: 'device-1',
              serverId: 'am-evn-01',
              protocol: target.protocol,
            ),
            killSwitch: false,
          ),
        );
        expect(target.startCount, greaterThan(0));
        expect(engine.capabilitiesFor(target.protocol).isMock, isTrue);
        await engine.disconnect(
            operationId: 'disconnect-${target.protocol.name}');
        expect(target.stopCount, greaterThan(0));
        await engine.dispose();
      }

      expect(wireGuard, isA<WireGuardAdapter>());
      expect(amnezia, isA<AmneziaWgAdapter>());
      expect(xray, isA<XrayRealityAdapter>());
    });

    test('mock capabilities do not claim unsupported system features',
        () async {
      final MockVpnEngine engine = MockVpnEngine();

      expect(engine.supportedProtocols, VpnProtocol.values.toSet());
      for (final VpnProtocol protocol in VpnProtocol.values) {
        final VpnAdapterCapabilities capabilities =
            engine.capabilitiesFor(protocol);
        expect(capabilities.supportsKillSwitch, isFalse);
        expect(capabilities.supportsDns, isFalse);
        expect(capabilities.supportsNetworkChangeReconnect, isFalse);
        expect(capabilities.supportsSleepRecovery, isFalse);
      }
      await engine.dispose();
    });

    test('emits a confirmed connection lifecycle', () async {
      final MockVpnEngine engine = MockVpnEngine();
      final List<VpnConnectionPhase> phases = <VpnConnectionPhase>[];
      final subscription = engine.states.listen(
        (VpnConnectionState state) => phases.add(state.phase),
      );

      await engine.connect(
        const ConnectionRequest(
          operationId: 'test-connect',
          profile: VpnProfile(
            id: 'profile-1',
            deviceId: 'device-1',
            serverId: 'am-evn-01',
            protocol: VpnProtocol.wireGuard,
          ),
          killSwitch: true,
        ),
      );

      final VpnConnectionState state = await engine.status();
      expect(state.phase, VpnConnectionPhase.connected);
      expect(state.killSwitchActive, isTrue);
      expect(phases, <VpnConnectionPhase>[
        VpnConnectionPhase.validating,
        VpnConnectionPhase.connecting,
        VpnConnectionPhase.connected,
      ]);

      await subscription.cancel();
      await engine.dispose();
    });
  });

  test('settings repository stores typed VPN preferences', () async {
    final MockSettingsRepository repository = MockSettingsRepository();
    final List<AppSettings> changes = <AppSettings>[];
    final subscription = repository.changes.listen(changes.add);
    final AppSettings updated = (await repository.load()).copyWith(
      protocol: ProtocolPreference.amneziaWg,
      defaultServerId: 'am-evn-01',
    );

    await repository.save(updated);

    expect((await repository.load()).protocol, ProtocolPreference.amneziaWg);
    expect(changes.single.protocol, ProtocolPreference.amneziaWg);
    await subscription.cancel();
    await repository.dispose();
  });

  test('stored settings survive repository recreation', () async {
    final InMemorySecureStorage storage = InMemorySecureStorage();
    final StoredSettingsRepository first = StoredSettingsRepository(
      secureStorage: storage,
    );
    final AppSettings expected = const AppSettings.defaults().copyWith(
      protocol: ProtocolPreference.vlessReality,
      dns: DnsPreference.system,
      defaultServerId: 'am-evn-01',
    );

    await first.save(expected);
    final StoredSettingsRepository restored = StoredSettingsRepository(
      secureStorage: storage,
    );

    expect((await restored.load()).protocol, ProtocolPreference.vlessReality);
    expect((await restored.load()).dns, DnsPreference.system);
    await first.dispose();
    await restored.dispose();
  });

  test('server repository filters and validates selection', () async {
    final MockServerRepository repository = MockServerRepository();
    final List<VpnServer> servers = await repository.getServers(query: 'Арм');

    expect(servers.single.id, 'am-evn-01');
    await expectLater(repository.selectServer('missing'), throwsArgumentError);
  });

  test('default mock catalog contains only current Armenia server', () async {
    final MockServerRepository repository = MockServerRepository(
      apiClient: MockApiClient(),
    );

    final List<VpnServer> servers = await repository.getServers();

    expect(servers, hasLength(1));
    expect(servers.single.countryName, 'Армения');
    expect(servers.single.isTest, isFalse);
    expect(servers.single.isRecommended, isTrue);
  });

  test('development catalog filters, sorts, favorites and pings', () async {
    final MockServerRepository repository = MockServerRepository(
      apiClient: MockApiClient(includeTestServers: true),
    );

    final List<VpnServer> all = await repository.getServers();
    expect(all, hasLength(5));
    expect(all.first.id, 'am-evn-01');
    expect(all.skip(1).every((VpnServer server) => server.isTest), isTrue);

    final List<VpnServer> germany = await repository.getServers(query: 'герм');
    expect(germany.single.id, 'de-fra-test-01');

    final List<VpnServer> byLatency = await repository.getServers(
      sort: ServerSort.latency,
    );
    expect(byLatency.take(3).map((VpnServer server) => server.id), <String>[
      'am-evn-01',
      'de-fra-test-01',
      'nl-ams-test-01',
    ]);

    await repository.toggleFavorite('am-evn-01');
    final List<VpnServer> favorites = await repository.getServers(
      favoritesOnly: true,
      sort: ServerSort.name,
    );
    expect(
        favorites.map((VpnServer server) => server.id),
        containsAll(<String>[
          'am-evn-01',
          'de-fra-test-01',
        ]));

    expect(
        await repository.ping('am-evn-01'), const Duration(milliseconds: 36));
    expect(
      (await repository.getSelectedServer())!.status.latency,
      const Duration(milliseconds: 36),
    );
  });

  test(
    'mock engine rejects overlapping connect and disconnect operations',
    () async {
      final MockVpnEngine engine = MockVpnEngine();
      final Future<void> connecting = engine.connect(
        const ConnectionRequest(
          operationId: 'connect-1',
          profile: VpnProfile(
            id: 'profile-1',
            deviceId: 'device-1',
            serverId: 'am-evn-01',
            protocol: VpnProtocol.amneziaWg,
          ),
          killSwitch: true,
        ),
      );

      await expectLater(
        engine.disconnect(operationId: 'disconnect-while-connecting'),
        throwsStateError,
      );
      await connecting;
      await engine.dispose();
    },
  );

  test('connection phase contains the required finite-state vocabulary', () {
    expect(
      VpnConnectionPhase.values.map((VpnConnectionPhase phase) => phase.name),
      <String>[
        'disconnected',
        'validating',
        'connecting',
        'connected',
        'reconnecting',
        'disconnecting',
        'blockedBySubscription',
        'noNetwork',
        'serverUnavailable',
        'error',
      ],
    );
  });

  test('mock engine emits every safe failure outcome', () async {
    final Map<MockConnectionScenario, VpnConnectionPhase> expectations =
        <MockConnectionScenario, VpnConnectionPhase>{
      MockConnectionScenario.blockedBySubscription:
          VpnConnectionPhase.blockedBySubscription,
      MockConnectionScenario.noNetwork: VpnConnectionPhase.noNetwork,
      MockConnectionScenario.serverUnavailable:
          VpnConnectionPhase.serverUnavailable,
      MockConnectionScenario.error: VpnConnectionPhase.error,
    };

    for (final MapEntry<MockConnectionScenario, VpnConnectionPhase> entry
        in expectations.entries) {
      final MockVpnEngine engine = MockVpnEngine(
        scenario: entry.key,
        transitionDelay: Duration.zero,
      );
      final List<VpnConnectionPhase> phases = <VpnConnectionPhase>[];
      final subscription = engine.states.listen(
        (VpnConnectionState state) => phases.add(state.phase),
      );

      await engine.connect(_request('failure-${entry.key.name}'));

      expect(phases, <VpnConnectionPhase>[
        VpnConnectionPhase.validating,
        entry.value,
      ]);
      engine.scenario = MockConnectionScenario.success;
      await engine.connect(_request('retry-${entry.key.name}'));
      expect((await engine.status()).phase, VpnConnectionPhase.connected);
      await subscription.cancel();
      await engine.dispose();
    }
  });

  test('mock engine simulates reconnection and keeps connection time',
      () async {
    final MockVpnEngine engine = MockVpnEngine(
      scenario: MockConnectionScenario.reconnectOnce,
      transitionDelay: Duration.zero,
    );
    final List<VpnConnectionState> states = <VpnConnectionState>[];
    final subscription = engine.states.listen(states.add);

    await engine.connect(_request('reconnect'));

    expect(
      states.map((VpnConnectionState state) => state.phase),
      <VpnConnectionPhase>[
        VpnConnectionPhase.validating,
        VpnConnectionPhase.connecting,
        VpnConnectionPhase.connected,
        VpnConnectionPhase.reconnecting,
        VpnConnectionPhase.connected,
      ],
    );
    expect(states[2].connectedAt, isNotNull);
    expect(states[4].connectedAt, states[2].connectedAt);
    await subscription.cancel();
    await engine.dispose();
  });

  test(
    'mock engine implements validation, statistics and diagnostics',
    () async {
      final MockVpnEngine engine = MockVpnEngine();
      const VpnProfile invalid = VpnProfile(
        id: '',
        deviceId: 'device-1',
        serverId: 'am-evn-01',
        protocol: VpnProtocol.vlessReality,
      );

      expect((await engine.validateProfile(invalid)).isValid, isFalse);
      expect((await engine.statistics()).bytesReceived, 0);
      final EngineDiagnostics diagnostics = await engine.collectDiagnostics();
      expect(diagnostics.codes, <String>['MOCK_ENGINE']);
      await engine.dispose();
    },
  );

  test('mock API records only method and path in its response', () async {
    final ApiClient client = MockApiClient();
    final ApiResponse response = await client.send(
      const ApiRequest(
        method: ApiMethod.post,
        path: '/api/v1/activate',
        body: <String, Object?>{'activation_key': 'mock-secret'},
      ),
    );

    expect(response.body, <String, Object?>{
      'mock': true,
      'method': 'post',
      'path': '/api/v1/activate',
    });
    expect(response.body.toString(), isNot(contains('mock-secret')));
  });

  test('development payment follows the confirmed lifecycle', () async {
    final MockPaymentProvider payments = MockPaymentProvider(
      transitionDelay: Duration.zero,
    );
    final List<PaymentPhase> phases = <PaymentPhase>[];
    final subscription = payments.states.listen(
      (PaymentState state) => phases.add(state.phase),
    );

    expect(payments.currentState.phase, PaymentPhase.idle);
    final PaymentSession session = await payments.createCheckout(
      planId: 'month-1',
    );
    expect(session.checkoutUri.host, 'example.invalid');
    expect(await payments.confirm(session.id), isTrue);
    expect(phases, <PaymentPhase>[
      PaymentPhase.creatingOrder,
      PaymentPhase.awaitingPayment,
      PaymentPhase.paid,
      PaymentPhase.subscriptionUpdating,
      PaymentPhase.paid,
    ]);

    await subscription.cancel();
    await payments.dispose();
  });

  test('development payment supports cancellation and failure', () async {
    final MockPaymentProvider cancelled = MockPaymentProvider(
      transitionDelay: Duration.zero,
    );
    final PaymentSession session = await cancelled.createCheckout(
      planId: 'month-3',
    );
    await cancelled.cancel(session.id);
    expect(cancelled.currentState.phase, PaymentPhase.cancelled);
    await cancelled.dispose();

    final MockPaymentProvider failed = MockPaymentProvider(
      scenario: MockPaymentScenario.orderFailure,
      transitionDelay: Duration.zero,
    );
    await expectLater(
      failed.createCheckout(planId: 'month-6'),
      throwsA(isA<PaymentException>()),
    );
    expect(failed.currentState.phase, PaymentPhase.failed);
    await failed.dispose();
  });

  test('production fallback cannot confirm a payment', () async {
    final UnavailablePaymentProvider payments = UnavailablePaymentProvider();

    expect(payments.isMock, isFalse);
    expect(payments.isAvailable, isFalse);
    expect(await payments.confirm('unconfirmed-order'), isFalse);
    await expectLater(
      payments.createCheckout(planId: 'month-12'),
      throwsA(isA<PaymentException>()),
    );
    expect(payments.currentState.phase, PaymentPhase.failed);
    await payments.dispose();
  });

  test('secure storage does not expose enumeration', () async {
    final SecureStorage storage = InMemorySecureStorage();
    await storage.write(key: 'token', value: 'secret');
    expect(await storage.read('token'), 'secret');
    await storage.clear();
    expect(await storage.read('token'), isNull);
  });
}

final class _TwoLocationActivationClient implements ActivationApiClient {
  @override
  bool get isMock => false;

  @override
  Future<ActivationResult> activate(ActivationKey activationKey) async =>
      ActivationResult(
        account: const Account(id: 'account-1'),
        subscription: Subscription(
          status: SubscriptionStatus.active,
          planName: 'Active',
          expiresAt: null,
          deviceLimit: 1,
          lastVerifiedAt: DateTime.utc(2026),
        ),
        vpnCredentials: const <VpnProtocol, String>{
          VpnProtocol.vlessReality: 'armenia-profile',
        },
        locationVlessCredentials: const <String, String>{
          'netherlands-1': 'netherlands-profile',
        },
      );
}

final class _WireGuardOnlyActivationClient implements ActivationApiClient {
  const _WireGuardOnlyActivationClient();

  @override
  bool get isMock => false;

  @override
  Future<ActivationResult> activate(ActivationKey activationKey) async =>
      ActivationResult(
        account: const Account(id: 'account-1'),
        subscription: Subscription(
          status: SubscriptionStatus.active,
          planName: 'Active',
          expiresAt: null,
          deviceLimit: 1,
          lastVerifiedAt: DateTime.utc(2026),
        ),
        vpnCredentials: const <VpnProtocol, String>{
          VpnProtocol.wireGuard: 'wireguard-profile',
        },
      );
}

String _testActivationKey() => <String>[
      '1234',
      '5678',
      '9012',
    ].join();

ConnectionRequest _request(String operationId) => ConnectionRequest(
      operationId: operationId,
      profile: const VpnProfile(
        id: 'profile-1',
        deviceId: 'device-1',
        serverId: 'am-evn-01',
        protocol: VpnProtocol.wireGuard,
      ),
      killSwitch: true,
    );
