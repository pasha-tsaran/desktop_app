import 'package:kenai_core/kenai_core.dart';
import 'package:test/test.dart';

void main() {
  test('mock speed test reports latency, download and upload', () async {
    final MockSpeedTestEngine engine = MockSpeedTestEngine(
      transitionDelay: Duration.zero,
    );
    final List<SpeedTestPhase> phases = <SpeedTestPhase>[];
    final subscription = engine.states.listen(
      (SpeedTestState state) => phases.add(state.phase),
    );

    await engine.start(serverId: 'am-evn-01');

    expect(phases, <SpeedTestPhase>[
      SpeedTestPhase.pinging,
      SpeedTestPhase.downloading,
      SpeedTestPhase.uploading,
      SpeedTestPhase.completed,
    ]);
    expect(engine.currentState.averageLatency?.inMilliseconds, 37);
    expect(engine.currentState.maximumLatency?.inMilliseconds, 41);
    expect(engine.currentState.downloadMbps, 86.4);
    expect(engine.currentState.uploadMbps, 31.7);
    expect(engine.currentState.estimatedBytesUsed, greaterThan(0));
    await subscription.cancel();
    await engine.dispose();
  });

  test('speed test can be stopped and rejects overlapping runs', () async {
    final MockSpeedTestEngine engine = MockSpeedTestEngine(
      transitionDelay: const Duration(seconds: 1),
    );
    final Future<void> running = engine.start(serverId: 'am-evn-01');
    await expectLater(
      engine.start(serverId: 'am-evn-01'),
      throwsStateError,
    );
    await engine.stop();
    await running;

    expect(engine.currentState.phase, SpeedTestPhase.cancelled);
    await engine.dispose();
  });

  test('release fallbacks never fake speed or signed updates', () async {
    final UnavailableSpeedTestEngine speed = UnavailableSpeedTestEngine();
    final UnavailableUpdateProvider updates = UnavailableUpdateProvider(
      currentVersion: '0.1.0',
    );

    expect(speed.isAvailable, isFalse);
    expect(speed.isMock, isFalse);
    await speed.start(serverId: 'am-evn-01');
    expect(speed.currentState.phase, SpeedTestPhase.failed);
    expect(updates.isAvailable, isFalse);
    expect(updates.verifiesSignatures, isFalse);
    expect(
      (await updates.checkForUpdates()).status,
      UpdateStatus.unavailable,
    );
    await speed.dispose();
  });

  test('application settings persist stage 7 preferences', () async {
    final InMemorySecureStorage storage = InMemorySecureStorage();
    final StoredSettingsRepository repository = StoredSettingsRepository(
      secureStorage: storage,
    );
    final AppSettings expected = const AppSettings.defaults().copyWith(
      theme: ThemePreference.dark,
      autoUpdate: true,
      trayEnabled: true,
      sendDiagnostics: true,
    );

    await repository.save(expected);
    final AppSettings restored = await StoredSettingsRepository(
      secureStorage: storage,
    ).load();

    expect(restored.theme, ThemePreference.dark);
    expect(restored.autoUpdate, isTrue);
    expect(restored.trayEnabled, isTrue);
    expect(restored.sendDiagnostics, isTrue);
    await repository.dispose();
  });
}
