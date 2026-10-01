import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/support_repository.dart';
import 'package:kenai_vpn_desktop/src/screens/support_screen.dart';

void main() {
  testWidgets(
      'ticket conversation tracks operator status and persists on reopening',
      (tester) async {
    tester.view.physicalSize = const Size(1266, 682);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = MockSupportRepository();
    Widget app() => MaterialApp(
        theme: KenaiTheme.light(),
        home: Scaffold(body: SupportScreen(repository: repository)));
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-create')));
    await tester.pumpAndSettle();
    expect(find.text('Хотите указать свое имя?'), findsNothing);
    expect(find.text('Укажите тему'), findsOneWidget);
    await tester.enterText(
        find.byKey(const Key('support-subject')), 'Не подключается VPN');
    await tester.enterText(
        find.byKey(const Key('support-description')), 'Ошибка при подключении');
    await tester.tap(find.byKey(const Key('support-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('support-guest-name')), 'Иван');
    await tester.tap(find.byKey(const Key('support-name-confirm')));
    await tester.pumpAndSettle();
    expect(repository.lastGuestName, 'Иван');
    expect(
        find.textContaining('Ожидаем технического эксперта'), findsOneWidget);
    final ticket = (await repository.tickets()).single;
    repository.setStatus(ticket.id, SupportStatus.inProgress);
    repository.receiveReply(ticket.id, 'Проверьте подключение к интернету.');
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('В работе'), findsWidgets);
    expect(find.text('Проверьте подключение к интернету.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('support-message')),
        'Проверил, интернет работает');
    await tester.tap(find.byKey(const Key('support-send')));
    await tester.pumpAndSettle();
    expect(find.text('Проверил, интернет работает'), findsOneWidget);
    repository.setStatus(ticket.id, SupportStatus.closed);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Закрыто'), findsWidgets);
    expect(find.byKey(const Key('support-message')), findsNothing);
    expect(find.byKey(const Key('support-reopen-form')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('support-ticket-${ticket.id}')));
    await tester.pumpAndSettle();
    expect(find.text('Проверил, интернет работает'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unconfigured support does not accept phantom tickets',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: KenaiTheme.dark(),
        home: const Scaffold(
            body: SupportScreen(repository: UnavailableSupportRepository()))));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('support-create')))
            .onPressed,
        isNull);
    expect(find.textContaining('Поддержка пока недоступна'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lost responses preserve drafts and retry without duplicates',
      (tester) async {
    tester.view.physicalSize = const Size(1266, 682);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final repository = _LostResponseRepository();
    await tester.pumpWidget(MaterialApp(
        theme: KenaiTheme.light(),
        home: Scaffold(body: SupportScreen(repository: repository))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('support-subject')), 'Ошибка');
    await tester.enterText(
        find.byKey(const Key('support-description')), 'Не подключается');
    await tester.tap(find.byKey(const Key('support-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-name-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-error')), findsOneWidget);
    expect(find.text('Не подключается'), findsOneWidget);
    await tester.tap(find.byKey(const Key('support-create')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('support-name-skip')));
    await tester.pumpAndSettle();
    final ticket = (await repository.tickets()).single;
    expect((await repository.thread(ticket.id)).messages.length, 2);
    await tester.enterText(
        find.byKey(const Key('support-message')), 'Проверил интернет');
    await tester.tap(find.byKey(const Key('support-refresh')));
    await tester.pumpAndSettle();
    expect(find.text('Проверил интернет'), findsOneWidget);
    await tester.tap(find.byKey(const Key('support-send')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('support-error')), findsOneWidget);
    expect(find.text('Проверил интернет'), findsOneWidget);
    await tester.tap(find.byKey(const Key('support-send')));
    await tester.pumpAndSettle();
    expect((await repository.thread(ticket.id)).messages.length, 3);
    expect(find.text('Проверил интернет'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
      'API support authenticates independently and retries with the same message ID',
      () async {
    final storage = InMemorySecureStorage();
    await storage.write(
        key: SecureAccountStorageKeys.activationKey, value: '123456789012');
    final api = _Api();
    final repository = ApiSupportRepository(
        api: api,
        storage: storage,
        build: const ClientBuildInfo(
            version: '2.2.2',
            buildNumber: '13',
            platform: DevicePlatform.windows));
    expect(await repository.available(), true);
    await repository.tickets();
    expect(api.requests.where((r) => r.path == '/api/v1/activate'), isEmpty);
    expect(api.requests.where((r) => r.path.endsWith('/session')).length, 1);
    await repository.send('ticket', requestId: 'stable-request', body: 'Hello');
    final posts =
        api.requests.where((r) => r.path.endsWith('/messages')).toList();
    expect(posts.length, 2);
    expect(posts.every((r) => r.body['request_id'] == 'stable-request'), true);
    expect(posts.every((r) => !r.body.containsKey('activation_key')), true);
    await storage.delete(SecureAccountStorageKeys.activationKey);
    await repository.tickets();
    expect(api.requests.last.headers['Authorization'], startsWith('Guest '));
  });

  test(
      'API support opens an isolated guest conversation without an activation key',
      () async {
    final storage = InMemorySecureStorage();
    final api = _Api();
    final repository = ApiSupportRepository(
        api: api,
        storage: storage,
        build: const ClientBuildInfo(
            version: '2.2.2',
            buildNumber: '13',
            platform: DevicePlatform.windows));
    await repository.tickets();
    await repository.tickets();
    final guestRequests =
        api.requests.where((r) => r.path.endsWith('/tickets')).toList();
    expect(guestRequests.length, 2);
    expect(api.requests.where((r) => r.path.endsWith('/session')), isEmpty);
    final authorization = guestRequests.first.headers['Authorization'];
    expect(authorization, startsWith('Guest '));
    expect(guestRequests.last.headers['Authorization'], authorization);
    expect(
        await storage.read('support.guest_token'), authorization!.substring(6));
  });
}

class _Api implements ApiClient {
  final List<ApiRequest> requests = [];
  bool expired = true;
  @override
  Future<ApiResponse> send(ApiRequest request) async {
    requests.add(request);
    if (request.path.endsWith('/config'))
      return const ApiResponse(statusCode: 200, body: {'available': true});
    if (request.path.endsWith('/session'))
      return const ApiResponse(
          statusCode: 200, body: {'access_token': 'support-only-token'});
    if (request.path.endsWith('/tickets'))
      return const ApiResponse(statusCode: 200, body: {'tickets': <Object?>[]});
    if (expired) {
      expired = false;
      return const ApiResponse(statusCode: 401, body: {});
    }
    return const ApiResponse(statusCode: 200, body: {'ok': true});
  }
}

class _LostResponseRepository implements SupportRepository {
  final delegate = MockSupportRepository();
  bool loseCreate = true, loseSend = true;
  @override
  Future<bool> available() => delegate.available();
  @override
  Future<List<SupportTicket>> tickets() => delegate.tickets();
  @override
  Future<SupportThread> thread(String id, {int after = 0}) =>
      delegate.thread(id, after: after);
  @override
  Future<SupportThread> create(
      {required String requestId,
      required String subject,
      required String body,
      String guestName = ''}) async {
    final result = await delegate.create(
        requestId: requestId,
        subject: subject,
        body: body,
        guestName: guestName);
    if (loseCreate) {
      loseCreate = false;
      throw const SupportException(SupportFailure.network);
    }
    return result;
  }

  @override
  Future<void> send(String id,
      {required String requestId, required String body}) async {
    await delegate.send(id, requestId: requestId, body: body);
    if (loseSend) {
      loseSend = false;
      throw const SupportException(SupportFailure.network);
    }
  }
}
