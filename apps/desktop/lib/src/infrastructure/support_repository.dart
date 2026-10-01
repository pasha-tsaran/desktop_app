import 'dart:math';

import 'package:kenai_core/kenai_core.dart';

final class ApiSupportRepository implements SupportRepository {
  ApiSupportRepository(
      {required this.api, required this.storage, required this.build});
  final ApiClient api;
  final SecureStorage storage;
  final ClientBuildInfo build;
  String? _token;
  String? _accountKey;
  String? _guestToken;
  bool _guestMode = false;
  DateTime _expiry = DateTime.fromMillisecondsSinceEpoch(0);
  static const _base = '/api/v1/support';
  static const _guestStorageKey = 'support.guest_token';

  SupportException _failure(ApiResponse response) =>
      SupportException(switch (response.statusCode) {
        401 ||
        403 =>
          _guestMode ? SupportFailure.unavailable : SupportFailure.signIn,
        404 || 503 => SupportFailure.unavailable,
        409 => response.body['detail'] == 'ticket_closed'
            ? SupportFailure.closed
            : SupportFailure.activeTicket,
        429 => SupportFailure.rateLimited,
        _ => SupportFailure.server,
      });

  Future<ApiResponse> _send(ApiRequest request) async {
    try {
      return await api.send(request);
    } on ApiClientException catch (e) {
      throw SupportException(e.failure == ApiTransportFailure.noNetwork ||
              e.failure == ApiTransportFailure.timeout
          ? SupportFailure.network
          : SupportFailure.server);
    }
  }

  Future<void> _authenticate({bool force = false}) async {
    final key = await storage.read(SecureAccountStorageKeys.activationKey);
    if (key == null || !RegExp(r'^\d{12}$').hasMatch(key)) {
      _token = null;
      _accountKey = null;
      _guestMode = true;
      var guestToken = await storage.read(_guestStorageKey);
      if (guestToken == null ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(guestToken)) {
        final random = Random.secure();
        guestToken = List<int>.generate(32, (_) => random.nextInt(256))
            .map((value) => value.toRadixString(16).padLeft(2, '0'))
            .join();
        await storage.write(key: _guestStorageKey, value: guestToken);
      }
      _guestToken = guestToken;
      return;
    }
    _guestMode = false;
    _guestToken = null;
    if (!force &&
        _token != null &&
        key == _accountKey &&
        DateTime.now().isBefore(_expiry)) return;
    _token = null;
    final response = await _send(ApiRequest(
        method: ApiMethod.post,
        path: '$_base/session',
        body: {'activation_key': key}));
    if (response.statusCode != 200) throw _failure(response);
    final token = response.body['access_token'];
    if (token is! String || token.isEmpty)
      throw const SupportException(SupportFailure.server);
    _token = token;
    _accountKey = key;
    _expiry = DateTime.now().add(const Duration(minutes: 55));
  }

  Future<Map<String, Object?>> _request(ApiMethod method, String path,
      {Map<String, Object?> body = const {},
      Map<String, String> query = const {}}) async {
    await _authenticate();
    Future<ApiResponse> send() => _send(ApiRequest(
        method: method,
        path: '$_base$path',
        headers: {
          'Authorization': _guestMode ? 'Guest $_guestToken' : 'Bearer $_token',
        },
        body: body,
        query: query));
    var response = await send();
    if (response.statusCode == 401 && !_guestMode) {
      await _authenticate(force: true);
      response = await send();
    }
    if (response.statusCode < 200 || response.statusCode >= 300)
      throw _failure(response);
    return response.body;
  }

  @override
  Future<bool> available() async {
    final response = await _send(
        const ApiRequest(method: ApiMethod.get, path: '$_base/config'));
    if (response.statusCode == 404 || response.statusCode == 503) return false;
    if (response.statusCode != 200) throw _failure(response);
    return response.body['available'] == true;
  }

  SupportTicket _ticket(Map<String, Object?> json) => SupportTicket(
      id: json['id'] as String,
      subject: json['subject'] as String,
      status: SupportStatus.parse(json['status'] as String));

  SupportThread _thread(Map<String, Object?> json) => SupportThread(
      ticket: _ticket(json['ticket'] as Map<String, Object?>),
      messages: (json['messages'] as List<Object?>).map((entry) {
        final m = entry! as Map<String, Object?>;
        return SupportMessage(
            id: m['id'] as int,
            author: m['author'] as String,
            body: m['body'] as String,
            createdAt: DateTime.parse(m['created_at'] as String));
      }).toList(),
      hasMore: json['has_more'] == true);

  @override
  Future<List<SupportTicket>> tickets() async {
    final tickets = <SupportTicket>[];
    var more = true;
    var offset = 0;
    while (more) {
      final result = await _request(ApiMethod.get, '/tickets',
          query: {'offset': '$offset'});
      final page = (result['tickets'] as List<Object?>)
          .map((t) => _ticket(t! as Map<String, Object?>))
          .toList();
      final ids = tickets.map((t) => t.id).toSet();
      tickets.addAll(page.where((t) => !ids.contains(t.id)));
      offset += page.length;
      more = result['has_more'] == true && page.isNotEmpty;
    }
    return tickets;
  }

  @override
  Future<SupportThread> thread(String id, {int after = 0}) async => _thread(
      await _request(ApiMethod.get, '/tickets/${Uri.encodeComponent(id)}',
          query: {'after': '$after'}));
  @override
  Future<SupportThread> create(
          {required String requestId,
          required String subject,
          required String body,
          String guestName = ''}) async =>
      _thread(await _request(ApiMethod.post, '/tickets', body: {
        'request_id': requestId,
        'subject': subject,
        'body': body,
        'guest_name': guestName,
        'client_version': build.version,
        'platform': build.platform.name,
      }));
  @override
  Future<void> send(String id,
      {required String requestId, required String body}) async {
    await _request(
        ApiMethod.post, '/tickets/${Uri.encodeComponent(id)}/messages',
        body: {'request_id': requestId, 'body': body});
  }
}

/// Local development adapter; it never sends messages outside this process.
final class MockSupportRepository implements SupportRepository {
  final Map<String, SupportThread> _threads = {};
  final Map<String, String> _requests = {};
  int _sequence = 0;
  bool enabled = true;
  String? lastGuestName;
  @override
  Future<bool> available() async => enabled;
  @override
  Future<List<SupportTicket>> tickets() async =>
      _threads.values.map((t) => t.ticket).toList().reversed.toList();
  @override
  Future<SupportThread> thread(String id, {int after = 0}) async {
    final t = _threads[id]!;
    return SupportThread(
        ticket: t.ticket,
        messages: t.messages.where((m) => m.id > after).toList());
  }

  SupportMessage _message(String author, String body) => SupportMessage(
      id: ++_sequence, author: author, body: body, createdAt: DateTime.now());
  @override
  Future<SupportThread> create(
      {required String requestId,
      required String subject,
      required String body,
      String guestName = ''}) async {
    lastGuestName = guestName;
    if (_requests.containsKey(requestId))
      return _threads[_requests[requestId]]!;
    if (_threads.values.any((t) => t.ticket.status != SupportStatus.closed))
      throw const SupportException(SupportFailure.activeTicket);
    final id = supportRequestId();
    final result = SupportThread(
        ticket: SupportTicket(
            id: id, subject: subject, status: SupportStatus.waiting),
        messages: [
          _message('user', body),
          _message(
              'system', 'Обращение принято. Ожидаем технического эксперта.')
        ]);
    _threads[id] = result;
    _requests[requestId] = id;
    return result;
  }

  @override
  Future<void> send(String id,
      {required String requestId, required String body}) async {
    if (_requests.containsKey(requestId)) return;
    if (_threads[id]!.ticket.status == SupportStatus.closed)
      throw const SupportException(SupportFailure.closed);
    final t = _threads[id]!;
    _threads[id] = SupportThread(
        ticket: t.ticket, messages: [...t.messages, _message('user', body)]);
    _requests[requestId] = id;
  }

  void setStatus(String id, SupportStatus status) {
    final t = _threads[id]!;
    _threads[id] = SupportThread(
        ticket:
            SupportTicket(id: id, subject: t.ticket.subject, status: status),
        messages: [...t.messages, _message('system', status.label)]);
  }

  void receiveReply(String id, String body) {
    final t = _threads[id]!;
    _threads[id] = SupportThread(
        ticket: t.ticket, messages: [...t.messages, _message('support', body)]);
  }
}
