import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/bootstrap.dart';

void main() {
  testWidgets('shows strictly linear tariffs without fake discounts', (
    WidgetTester tester,
  ) async {
    final MockPaymentProvider payments = MockPaymentProvider();
    addTearDown(payments.dispose);
    await _openPlans(tester, _dependencies(payments));

    expect(find.text('1 месяц'), findsOneWidget);
    expect(find.text('3 месяцев'), findsOneWidget);
    expect(find.text('6 месяцев'), findsOneWidget);
    expect(find.text('12 месяцев'), findsOneWidget);
    expect(find.text('250 ₽'), findsOneWidget);
    expect(find.text('750 ₽'), findsOneWidget);
    expect(find.text('1 500 ₽'), findsOneWidget);
    expect(find.text('3 000 ₽'), findsOneWidget);
    expect(find.text('250 ₽ / месяц'), findsNWidgets(4));
    expect(find.textContaining('скид'), findsNothing);
  });

  testWidgets('renders every development payment state', (
    WidgetTester tester,
  ) async {
    final MockPaymentProvider payments = MockPaymentProvider();
    addTearDown(payments.dispose);
    await _openPlans(tester, _dependencies(payments));

    expect(_phase(tester), 'Выберите период');
    await tester.tap(find.byKey(const Key('tariff-3')));
    await tester.tap(find.byKey(const Key('buy-tariff')));
    await tester.pump();
    expect(_phase(tester), 'Создаём заказ');

    await tester.pump(const Duration(milliseconds: 61));
    expect(_phase(tester), 'Ожидаем оплату');

    await tester.tap(find.byKey(const Key('mock-confirm-payment')));
    await tester.pump(const Duration(milliseconds: 61));
    expect(_phase(tester), 'Оплата подтверждена');
    await tester.pump(const Duration(milliseconds: 61));
    expect(_phase(tester), 'Обновляем подписку');
    await tester.pump(const Duration(milliseconds: 61));
    expect(_phase(tester), 'Оплата подтверждена');

    final MockPaymentProvider cancelled = MockPaymentProvider();
    addTearDown(cancelled.dispose);
    await _openPlans(tester, _dependencies(cancelled));
    await tester.tap(find.byKey(const Key('buy-tariff')));
    await tester.pump(const Duration(milliseconds: 61));
    await tester.tap(find.byKey(const Key('cancel-payment')));
    await tester.pump();
    expect(_phase(tester), 'Оплата отменена');

    final MockPaymentProvider failed = MockPaymentProvider(
      scenario: MockPaymentScenario.orderFailure,
    );
    addTearDown(failed.dispose);
    await _openPlans(tester, _dependencies(failed));
    await tester.tap(find.byKey(const Key('buy-tariff')));
    await tester.pump(const Duration(milliseconds: 61));
    expect(_phase(tester), 'Ошибка оплаты');
  });

  testWidgets('production fallback cannot display successful payment', (
    WidgetTester tester,
  ) async {
    final UnavailablePaymentProvider payments = UnavailablePaymentProvider();
    addTearDown(payments.dispose);
    await _openPlans(tester, _dependencies(payments));

    expect(
      find.byKey(const Key('production-payment-unavailable')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('mock-payment-badge')), findsNothing);
    expect(find.byKey(const Key('mock-confirm-payment')), findsNothing);
    expect(find.text('Оплата подтверждена'), findsNothing);
    expect(find.byKey(const Key('buy-tariff')), findsNothing);
  });
}

AppDependencies _dependencies(PaymentProvider payments) {
  final MockApiClient apiClient = MockApiClient();
  final InMemorySecureStorage storage = InMemorySecureStorage();
  return AppDependencies(
    apiClient: apiClient,
    secureStorage: storage,
    accountRepository: SecureAccountRepository(
      apiClient: MockActivationApiClient(),
      secureStorage: storage,
    ),
    vpnEngine: MockVpnEngine(),
    serverRepository: MockServerRepository(apiClient: apiClient),
    settingsRepository: MockSettingsRepository(),
    platformCapabilities: const ClientPlatformCapabilities.unavailable(),
    subscriptionRepository: MockSubscriptionRepository(),
    paymentProvider: payments,
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
  );
}

Future<void> _openPlans(
  WidgetTester tester,
  AppDependencies dependencies,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(buildKenaiApp(dependencies: dependencies));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('nav-plans')),
    150,
    scrollable: find.descendant(
      of: find.byKey(const Key('sidebar-navigation')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('nav-plans')));
  await tester.pumpAndSettle();
}

String? _phase(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('payment-phase'))).data;
