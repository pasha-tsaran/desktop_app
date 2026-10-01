import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/support_repository.dart';
import 'package:kenai_vpn_desktop/src/visual/connection_art.dart';

void main() {
  testWidgets('Netherlands connected production layout fits the window',
      (tester) async {
    _useWideWindow(tester);
    if (const bool.fromEnvironment('KENAI_CAPTURE_UI')) {
      final font = FontLoader('Segoe UI')
        ..addFont(Future.value(ByteData.sublistView(
            File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync())));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future.value(ByteData.sublistView(File(
                'C:/Users/tsara/development/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytesSync())));
      await icons.load();
    }
    final repository = ArmeniaMvpServerRepository();
    await repository.selectServer('netherlands-1');
    final fixture = _fixture(serverRepository: repository);
    final settings = await fixture.dependencies.settingsRepository.load();
    await fixture.dependencies.settingsRepository
        .save(settings.copyWith(theme: ThemePreference.dark));
    addTearDown(fixture.engine.dispose);
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: key, child: buildKenaiApp(dependencies: fixture.dependencies)));
    await tester.pumpAndSettle();
    fixture.engine.simulateState(VpnConnectionState(
        phase: VpnConnectionPhase.connected,
        serverId: 'netherlands-1',
        protocol: VpnProtocol.vlessReality,
        connectedAt: DateTime.now()));
    await tester.pump();
    expect(find.byKey(const ValueKey('netherlands-art')), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (const bool.fromEnvironment('KENAI_CAPTURE_UI')) {
      final context = tester.element(find.byType(ConnectionArt));
      await tester.runAsync(() =>
          precacheImage(const AssetImage('assets/visual/orb.png'), context));
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../output/ui-review/netherlands-connected.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('IP refresh ignores stale results and never polls while idle',
      (tester) async {
    _useWideWindow(tester);
    final probe = _ControlledIpProbe();
    final fixture = _fixture(publicIpProbe: probe);
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();
    expect(probe.requests, hasLength(1));
    fixture.engine.simulateState(const VpnConnectionState(
        phase: VpnConnectionPhase.connected,
        serverId: 'am-evn-01',
        protocol: VpnProtocol.vlessReality));
    await tester.pump();
    expect(probe.requests, hasLength(2));
    probe.requests[1].complete('203.0.113.20');
    await tester.pump();
    expect(find.text('203.0.113.20'), findsOneWidget);
    probe.requests[0].complete('198.51.100.10');
    await tester.pump();
    expect(find.text('198.51.100.10'), findsNothing);
    await tester.pump(const Duration(seconds: 30));
    expect(probe.requests, hasLength(2));
    fixture.engine.simulateState(const VpnConnectionState.disconnected());
    await tester.pump();
    expect(find.text('203.0.113.20'), findsNothing);
    probe.requests[2].complete('198.51.100.10');
    await tester.pump();
    expect(find.text('198.51.100.10'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Netherlands shows regional art only while connected',
      (tester) async {
    for (final connected in [false, true]) {
      await tester.pumpWidget(MaterialApp(
          home: SizedBox(
              width: 580,
              height: 620,
              child: ConnectionArt(
                  dark: true,
                  connected: connected,
                  countryCode: 'NL',
                  countryName: 'Нидерланды'))));
      expect(find.byKey(const ValueKey('netherlands-art')),
          connected ? findsOneWidget : findsNothing);
      expect(
          find.text('Нидерланды'), connected ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('unknown production health is not displayed as unverified',
      (tester) async {
    _useWideWindow(tester);
    final fixture = _fixture(serverRepository: ArmeniaMvpServerRepository());
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();
    expect(find.text('Не проверен'), findsNothing);
    expect(find.byKey(const Key('server-netherlands-1')), findsOneWidget);
  });
  test('orb motion has matching position and velocity at the loop boundary',
      () {
    expect((orbOffset(0) - orbOffset(1)).distance, lessThan(1e-10));
    const step = .000001;
    final before = (orbOffset(1) - orbOffset(1 - step)) / step;
    final after = (orbOffset(step) - orbOffset(0)) / step;
    expect((before - after).distance, lessThan(.02));
  });

  testWidgets('connection layout keeps its geometry in four visual states',
      (tester) async {
    _useWideWindow(tester);
    const capture = bool.fromEnvironment('KENAI_CAPTURE_UI');
    if (capture) {
      tester.view.physicalSize = const Size(1672, 941);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
      final font = FontLoader('Segoe UI')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(
            File('C:/Windows/Fonts/segoeui.ttf').readAsBytesSync())));
      await font.load();
      final icons = FontLoader('MaterialIcons')
        ..addFont(Future<ByteData>.value(ByteData.sublistView(File(
                'C:/Users/tsara/development/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytesSync())));
      await icons.load();
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
    }
    final fixture =
        _fixture(includeTestServers: capture, minimalMvpMode: capture);
    addTearDown(fixture.engine.dispose);
    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
        key: captureKey,
        child: buildKenaiApp(dependencies: fixture.dependencies)));
    await tester.pumpAndSettle();
    if (capture) {
      final context = tester.element(find.byType(ConnectionArt));
      await tester.runAsync(() => Future.wait([
            precacheImage(const AssetImage('assets/visual/globe.png'), context),
            precacheImage(
                const AssetImage('assets/visual/armenia-map.png'), context),
            precacheImage(const AssetImage('assets/visual/orb.png'), context),
          ]));
      await tester.pumpAndSettle();
    }
    Future<void> captureFrame(String name) async {
      await tester.runAsync(() async {
        final boundary = captureKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('../../output/ui-review/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    Rect? referenceOrb;
    for (final theme in <ThemePreference>[
      ThemePreference.light,
      ThemePreference.dark,
    ]) {
      final settings = await fixture.dependencies.settingsRepository.load();
      await fixture.dependencies.settingsRepository
          .save(settings.copyWith(theme: theme));
      await tester.pumpAndSettle();
      for (final connected in <bool>[false, true]) {
        fixture.engine.simulateState(connected
            ? VpnConnectionState(
                phase: VpnConnectionPhase.connected,
                serverId: 'am-evn-01',
                protocol: VpnProtocol.wireGuard,
                connectedAt: DateTime.now(),
              )
            : const VpnConnectionState.disconnected());
        await tester.pump();
        final orb = tester.getRect(find.byType(ConnectionOrb));
        referenceOrb ??= orb;
        expect(orb.size, referenceOrb.size);
        expect(find.byKey(const Key('connect-button')).hitTestable(),
            findsOneWidget);
        expect(find.text(connected ? 'VPN подключён' : 'VPN не подключён'),
            findsOneWidget);
        expect(tester.widget<ConnectionArt>(find.byType(ConnectionArt)).dark,
            theme == ThemePreference.dark);
        if (!connected) {
          final globe = find.byKey(const ValueKey('globe-art'));
          expect(tester.widget<Image>(globe).fit, BoxFit.contain);
          final globeSize = tester.getSize(globe);
          expect(globeSize.width / globeSize.height, closeTo(1672 / 941, .001));
        }
        expect(tester.takeException(), isNull);
        if (capture) {
          await tester.pumpAndSettle();
          await captureFrame(
              '${theme.name}-${connected ? 'connected' : 'disconnected'}');
        }
      }
      fixture.engine.simulateState(const VpnConnectionState.disconnected());
      for (final destination in [
        'account',
        'logs',
        'vpnSettings',
        'settings',
        'support'
      ]) {
        await tester.tap(find.byKey(Key('nav-$destination')));
        await tester.pumpAndSettle();
        expect(find.byType(ConnectionArt), findsNothing);
        expect(tester.takeException(), isNull);
        if (capture) await captureFrame('${theme.name}-$destination');
        if (capture && destination == 'support') {
          final support =
              fixture.dependencies.supportRepository as MockSupportRepository;
          final thread = await support.create(
              requestId: supportRequestId(),
              subject: 'Не удаётся подключиться',
              body: 'При подключении появляется ошибка. Интернет работает.');
          support.setStatus(thread.ticket.id, SupportStatus.inProgress);
          support.receiveReply(thread.ticket.id,
              'Здравствуйте! Уточните, какой протокол выбран в настройках VPN.');
          await tester.tap(find.byKey(const Key('support-refresh')));
          await tester.pumpAndSettle();
          await captureFrame('${theme.name}-support-chat');
          tester.view.physicalSize = const Size(1266, 682);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('nav-support')).hitTestable(),
              findsOneWidget);
          expect(tester.takeException(), isNull);
          await captureFrame('${theme.name}-support-chat-compact');
          tester.view.physicalSize = const Size(1672, 941);
          await tester.pumpAndSettle();
          support.setStatus(thread.ticket.id, SupportStatus.closed);
        }
      }
      await tester.tap(find.byKey(const Key('nav-servers')));
      await tester.pumpAndSettle();
    }
    debugDisableShadows = true;
  });

  testWidgets('pending connection button stays enabled for cancellation',
      (tester) async {
    _useWideWindow(tester);
    final fixture = _fixture(includeTestServers: false);
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();
    for (final phase in [
      VpnConnectionPhase.validating,
      VpnConnectionPhase.connecting,
      VpnConnectionPhase.reconnecting,
      VpnConnectionPhase.disconnecting
    ]) {
      fixture.engine.simulateState(VpnConnectionState(phase: phase));
      await tester.pump();
      expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('connect-button')))
              .onPressed,
          isNotNull);
      expect(find.text('Отменить подключение'), findsOneWidget);
    }
    fixture.engine.simulateState(const VpnConnectionState.disconnected());
    await tester.pumpAndSettle();
  });
  testWidgets('opens servers and navigates to settings', (
    WidgetTester tester,
  ) async {
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture(includeTestServers: false);
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();

    expect(find.text('Серверы'), findsWidgets);
    expect(find.textContaining('Ереван'), findsWidgets);
    expect(find.byKey(const Key('mock-api-badge')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nav-settings')));
    await tester.pumpAndSettle();

    expect(find.text('Параметры'), findsWidgets);
    expect(find.byKey(const Key('application-version')), findsOneWidget);
  });

  testWidgets('development catalog supports search and favorites', (
    WidgetTester tester,
  ) async {
    _useWideWindow(tester);
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture();
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();

    expect(find.text('Mock API · тестовые серверы'), findsOneWidget);
    expect(find.textContaining('Yerevan S1'), findsWidgets);
    expect(_visibleServer('de-fra-test-01'), findsOneWidget);
    expect(find.text('Тестовый'), findsWidgets);
    expect(find.text('Рекомендуемый'), findsWidgets);

    await tester.enterText(find.byKey(const Key('server-search')), 'Герм');
    await tester.pumpAndSettle();
    expect(_visibleServer('de-fra-test-01'), findsOneWidget);
    expect(_visibleServer('am-evn-01'), findsNothing);

    expect(find.byKey(const Key('country-all')), findsOneWidget);
    expect(find.byKey(const Key('country-DE')), findsNothing);
    await tester.enterText(find.byKey(const Key('server-search')), '');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('country-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('country-DE')));
    await tester.pumpAndSettle();
    expect(_visibleServer('de-fra-test-01'), findsOneWidget);
    expect(_visibleServer('am-evn-01'), findsNothing);
    await tester.tap(find.byKey(const Key('country-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Все страны').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('favorite-am-evn-01')).hitTestable().first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('favorites-filter')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Yerevan S1'), findsWidgets);
    expect(_visibleServer('de-fra-test-01'), findsOneWidget);
    expect(_visibleServer('jp-tyo-test-01'), findsNothing);
  });

  testWidgets('selected server shows protocol, ping and availability', (
    WidgetTester tester,
  ) async {
    _useWideWindow(tester);
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture();
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();

    expect(find.text('WireGuard'), findsOneWidget);
    expect(find.text('38 ms'), findsWidgets);
    await tester.tap(find.byKey(const Key('ping-button')));
    await tester.pumpAndSettle();
    expect(find.text('36 ms'), findsWidgets);
    expect(find.byKey(const Key('selected-ping')), findsNothing);

    final Finder tokyo = find
        .byKey(
          const Key('server-jp-tyo-test-01'),
        )
        .first;
    await tester.ensureVisible(tokyo);
    await tester.pumpAndSettle();
    await tester.tap(tokyo);
    await tester.pumpAndSettle();
    expect(find.text('Тестовый сервер'), findsOneWidget);
    expect(find.text('Недоступен'), findsWidgets);
    final FilledButton connectButton = tester.widget<FilledButton>(
      find.byKey(const Key('connect-button')),
    );
    expect(connectButton.onPressed, isNull);
  });

  testWidgets('connection details fit the standard window without scrolling', (
    WidgetTester tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1266, 682);
    addTearDown(tester.view.reset);
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture();
    addTearDown(fixture.engine.dispose);

    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();

    final Finder panel = find.byKey(const Key('connection-panel'));
    expect(panel, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.byType(SingleChildScrollView)),
      findsNothing,
    );
    expect(find.byKey(const Key('traffic-sent')), findsOneWidget);
    for (final VpnProtocol protocol in <VpnProtocol>[
      VpnProtocol.vlessReality,
      VpnProtocol.amneziaWg,
    ]) {
      fixture.engine.simulateState(VpnConnectionState(
        phase: VpnConnectionPhase.connected,
        protocol: protocol,
        serverId: 'am-evn-01',
        connectedAt: DateTime.now(),
      ));
      await tester.pump();
      final Rect panelRect = tester.getRect(panel);
      final Rect trafficRect =
          tester.getRect(find.byKey(const Key('traffic-sent')));
      expect(panelRect.contains(trafficRect.bottomRight), isTrue);
      expect(find.byKey(const Key('connect-button')).hitTestable(),
          findsOneWidget);
      expect(
          find.byKey(const Key('ping-button')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('connect button shows lifecycle, time and traffic', (
    WidgetTester tester,
  ) async {
    _useWideWindow(tester);
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture();
    await tester.pumpWidget(
      buildKenaiApp(dependencies: fixture.dependencies),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(_phaseText(tester), 'Проверяем профиль');

    await tester.pump(const Duration(milliseconds: 81));
    expect(_phaseText(tester), 'Подключаемся');

    await tester.pump(const Duration(milliseconds: 81));
    expect(_phaseText(tester), 'VPN подключён');
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('connection-time')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('traffic-received')),
        matching: find.text('0 Б'),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pump();
    expect(_phaseText(tester), 'Отключаем VPN');
    await tester.pump(const Duration(milliseconds: 81));
    expect(_phaseText(tester), 'VPN не подключён');
    expect(find.text('0 Б'), findsWidgets);
    await fixture.engine.dispose();
  });

  testWidgets('renders every connection state without internal error details', (
    WidgetTester tester,
  ) async {
    _useWideWindow(tester);
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture();
    await tester.pumpWidget(
      buildKenaiApp(dependencies: fixture.dependencies),
    );
    await tester.pumpAndSettle();

    final Map<VpnConnectionPhase, String> titles = <VpnConnectionPhase, String>{
      VpnConnectionPhase.disconnected: 'VPN не подключён',
      VpnConnectionPhase.validating: 'Проверяем профиль',
      VpnConnectionPhase.connecting: 'Подключаемся',
      VpnConnectionPhase.connected: 'VPN подключён',
      VpnConnectionPhase.reconnecting: 'Восстанавливаем соединение',
      VpnConnectionPhase.disconnecting: 'Отключаем VPN',
      VpnConnectionPhase.blockedBySubscription: 'Подключение приостановлено',
      VpnConnectionPhase.noNetwork: 'Нет подключения к интернету',
      VpnConnectionPhase.serverUnavailable: 'Сервер временно недоступен',
      VpnConnectionPhase.error: 'Не удалось подключиться',
    };

    for (final MapEntry<VpnConnectionPhase, String> entry in titles.entries) {
      fixture.engine.simulateState(
        VpnConnectionState(
          phase: entry.key,
          serverId: 'am-evn-01',
          protocol: VpnProtocol.wireGuard,
          connectedAt:
              entry.key == VpnConnectionPhase.connected ? DateTime.now() : null,
          errorCode: 'INTERNAL_SECRET_DETAIL',
        ),
      );
      await tester.pump();
      expect(_phaseText(tester), entry.value);
      expect(find.textContaining('INTERNAL_SECRET_DETAIL'), findsNothing);
    }

    fixture.engine.simulateState(const VpnConnectionState(
      phase: VpnConnectionPhase.error,
      serverId: 'am-evn-01',
      protocol: VpnProtocol.vlessReality,
      errorCode: 'TUNNEL_ROUTE_UNAVAILABLE',
    ));
    await tester.pump();
    expect(_phaseText(tester), 'Туннель не направляет трафик');
    expect(
        find.text('Не удалось настроить маршруты VPN. Откройте диагностику.'),
        findsOneWidget);

    fixture.engine.simulateState(const VpnConnectionState.disconnected());
    await tester.pump();
    await fixture.engine.dispose();
  });

  testWidgets('minimal release navigation hides unfinished sections', (
    WidgetTester tester,
  ) async {
    final ({AppDependencies dependencies, MockVpnEngine engine}) fixture =
        _fixture(minimalMvpMode: true);
    addTearDown(fixture.engine.dispose);
    await tester.pumpWidget(buildKenaiApp(dependencies: fixture.dependencies));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.credit_card_outlined), findsNothing);
    expect(find.byIcon(Icons.monitor_heart_outlined), findsNothing);
    expect(find.byIcon(Icons.speed_outlined), findsNothing);
    expect(find.byKey(const Key('nav-account')), findsOneWidget);
    expect(find.byKey(const Key('nav-settings')), findsOneWidget);
  });
}

({AppDependencies dependencies, MockVpnEngine engine}) _fixture({
  bool includeTestServers = true,
  bool minimalMvpMode = false,
  PublicIpProbe publicIpProbe = const UnavailablePublicIpProbe(),
  ServerRepository? serverRepository,
}) {
  final MockApiClient api = MockApiClient(
    includeTestServers: includeTestServers,
  );
  final MockVpnEngine engine = MockVpnEngine();
  final InMemorySecureStorage secureStorage = InMemorySecureStorage();
  return (
    dependencies: AppDependencies(
      publicIpProbe: publicIpProbe,
      apiClient: api,
      supportRepository: MockSupportRepository(),
      secureStorage: secureStorage,
      accountRepository: SecureAccountRepository(
        apiClient: MockActivationApiClient(),
        secureStorage: secureStorage,
      ),
      vpnEngine: engine,
      serverRepository:
          serverRepository ?? MockServerRepository(apiClient: api),
      settingsRepository: MockSettingsRepository(),
      platformCapabilities: const ClientPlatformCapabilities.unavailable(),
      subscriptionRepository: MockSubscriptionRepository(),
      paymentProvider: MockPaymentProvider(),
      speedTestEngine: MockSpeedTestEngine(),
      updateProvider: MockUpdateProvider(),
      buildInfo: const ClientBuildInfo(
        version: '0.1.0',
        buildNumber: '1',
        platform: DevicePlatform.windows,
      ),
      diagnosticLogger: RedactingDiagnostics(
        store: InMemoryDiagnosticLogStore(),
      ),
      diagnosticExporter: MockDiagnosticExporter(),
      diagnosticArchiveSaver: InMemoryDiagnosticArchiveSaver(),
      minimalMvpMode: minimalMvpMode,
    ),
    engine: engine,
  );
}

String? _phaseText(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('connection-phase'))).data;

void _useWideWindow(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
}

Finder _visibleServer(String id) => find.byKey(Key('server-$id')).hitTestable();

final class _ControlledIpProbe implements PublicIpProbe {
  final requests = <Completer<String?>>[];
  @override
  Future<String?> measure() {
    final request = Completer<String?>();
    requests.add(request);
    return request.future;
  }
}
