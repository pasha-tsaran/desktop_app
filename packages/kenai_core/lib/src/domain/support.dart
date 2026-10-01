import 'dart:math';

enum SupportStatus {
  waiting('Ожидает специалиста'),
  inProgress('В работе'),
  closed('Закрыто');

  const SupportStatus(this.label);
  final String label;
  static SupportStatus parse(String value) => switch (value) {
        'waiting' => waiting,
        'in_progress' => inProgress,
        'closed' => closed,
        _ => throw const FormatException('Invalid support status'),
      };
}

final class SupportTicket {
  const SupportTicket(
      {required this.id, required this.subject, required this.status});
  final String id;
  final String subject;
  final SupportStatus status;
}

final class SupportMessage {
  const SupportMessage(
      {required this.id,
      required this.author,
      required this.body,
      required this.createdAt});
  final int id;
  final String author;
  final String body;
  final DateTime createdAt;
}

final class SupportThread {
  const SupportThread(
      {required this.ticket, required this.messages, this.hasMore = false});
  final SupportTicket ticket;
  final List<SupportMessage> messages;
  final bool hasMore;
}

enum SupportFailure {
  signIn,
  unavailable,
  network,
  activeTicket,
  closed,
  rateLimited,
  server
}

final class SupportException implements Exception {
  const SupportException(this.failure);
  final SupportFailure failure;
  String get message => switch (failure) {
        SupportFailure.signIn =>
          'Для обращения в поддержку активируйте аккаунт.',
        SupportFailure.unavailable =>
          'Поддержка пока недоступна. Попробуйте позже.',
        SupportFailure.network =>
          'Нет связи с поддержкой. Проверьте интернет и повторите попытку.',
        SupportFailure.activeTicket =>
          'У вас уже есть открытое обращение. Продолжите переписку в нём.',
        SupportFailure.closed =>
          'Обращение уже закрыто. Вы можете создать новое.',
        SupportFailure.rateLimited =>
          'Слишком много сообщений. Подождите немного и повторите попытку.',
        SupportFailure.server =>
          'Не удалось выполнить действие. Повторите попытку.',
      };
  @override
  String toString() => 'SupportException(${failure.name})';
}

abstract interface class SupportRepository {
  Future<bool> available();
  Future<List<SupportTicket>> tickets();
  Future<SupportThread> thread(String id, {int after = 0});
  Future<SupportThread> create(
      {required String requestId,
      required String subject,
      required String body,
      String guestName = ''});
  Future<void> send(String id,
      {required String requestId, required String body});
}

final class UnavailableSupportRepository implements SupportRepository {
  const UnavailableSupportRepository();
  @override
  Future<bool> available() async => false;
  @override
  Future<List<SupportTicket>> tickets() async => [];
  @override
  Future<SupportThread> thread(String id, {int after = 0}) async =>
      throw const SupportException(SupportFailure.unavailable);
  @override
  Future<SupportThread> create(
          {required String requestId,
          required String subject,
          required String body,
          String guestName = ''}) async =>
      throw const SupportException(SupportFailure.unavailable);
  @override
  Future<void> send(String id,
          {required String requestId, required String body}) async =>
      throw const SupportException(SupportFailure.unavailable);
}

String supportRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
