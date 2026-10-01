import 'package:kenai_core/kenai_core.dart';
import 'package:test/test.dart';

void main() {
  test('Netherlands ping uses its own probe and preserves unknown health',
      () async {
    final repository = ArmeniaMvpServerRepository(
      latencyProbe: const _FixedLatencyProbe(Duration(milliseconds: 42)),
      netherlandsLatencyProbe:
          const _FixedLatencyProbe(Duration(milliseconds: 85)),
    );
    expect(await repository.ping('netherlands-1'),
        const Duration(milliseconds: 85));
    final servers = await repository.getServers();
    expect(servers.first.status.latency, isNull);
    expect(servers.last.status.latency, const Duration(milliseconds: 85));
    expect(servers.last.status.operational, ServerOperationalStatus.unknown);
  });
  test('production repository exposes separate Armenia and Netherlands exits',
      () async {
    final ArmeniaMvpServerRepository repository = ArmeniaMvpServerRepository();

    final List<VpnServer> servers = await repository.getServers();

    expect(repository.isMock, isFalse);
    expect(servers, hasLength(2));
    final VpnServer armenia = servers.first;
    final VpnServer netherlands = servers.last;
    expect(armenia.countryCode, 'AM');
    expect(armenia.isTest, isFalse);
    expect(armenia.protocols, <VpnProtocol>{
      VpnProtocol.vlessReality,
      VpnProtocol.amneziaWg,
    });
    expect(armenia.isAvailable, isFalse);
    expect(armenia.canAttemptConnection, isTrue);
    expect(netherlands.countryCode, 'NL');
    expect(netherlands.protocols, <VpnProtocol>{VpnProtocol.vlessReality});
    await repository.selectServer('netherlands-1');
    expect((await repository.getSelectedServer())?.id, 'netherlands-1');
    expect(
      armenia
          .copyWith(
            status: ServerStatus(
              operational: ServerOperationalStatus.offline,
              internetReachability: InternetReachability.unknown,
              lastUpdatedAt: DateTime.utc(2026, 9, 13),
            ),
          )
          .canAttemptConnection,
      isFalse,
    );
    expect(await repository.getServers(query: 'Германия'), isEmpty);
  });

  test('MVP server repository records measured production latency', () async {
    final ArmeniaMvpServerRepository repository = ArmeniaMvpServerRepository(
      latencyProbe: const _FixedLatencyProbe(Duration(milliseconds: 42)),
    );

    expect(
        await repository.ping('armenia-1'), const Duration(milliseconds: 42));
    expect(
      (await repository.getSelectedServer())?.status.latency,
      const Duration(milliseconds: 42),
    );
  });

  test('unavailable release engine never reports a connection', () async {
    final UnavailableVpnEngine engine = UnavailableVpnEngine();
    final List<VpnConnectionState> states = <VpnConnectionState>[];
    final subscription = engine.states.listen(states.add);

    await engine.connect(
      const ConnectionRequest(
        operationId: 'connect-1',
        profile: VpnProfile(
          id: 'profile-armenia-1-wireGuard',
          deviceId: 'local-windows-device',
          serverId: 'armenia-1',
          protocol: VpnProtocol.wireGuard,
        ),
        killSwitch: false,
      ),
    );

    expect(engine.isMock, isFalse);
    expect(engine.supportedProtocols, isEmpty);
    expect(states.single.phase, VpnConnectionPhase.error);
    expect(states.single.errorCode, 'ENGINE_NOT_INSTALLED');
    expect((await engine.status()).phase, isNot(VpnConnectionPhase.connected));
    await subscription.cancel();
  });
}

final class _FixedLatencyProbe implements ServerLatencyProbe {
  const _FixedLatencyProbe(this.latency);

  final Duration latency;

  @override
  Future<Duration?> measure() async => latency;
}
