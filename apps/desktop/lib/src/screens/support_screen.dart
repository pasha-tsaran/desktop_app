import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';

final class SupportScreen extends StatefulWidget {
  const SupportScreen(
      {required this.repository, this.onOpenAccount, super.key});
  final SupportRepository repository;
  final VoidCallback? onOpenAccount;
  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

final class _SupportNameDialog extends StatefulWidget {
  const _SupportNameDialog();

  @override
  State<_SupportNameDialog> createState() => _SupportNameDialogState();
}

final class _SupportNameDialogState extends State<_SupportNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Хотите указать свое имя?'),
        content: TextField(
            key: const Key('support-guest-name'),
            controller: _name,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
                labelText: 'Имя', hintText: 'Необязательно')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена')),
          TextButton(
              key: const Key('support-name-skip'),
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Не указывать')),
          FilledButton(
              key: const Key('support-name-confirm'),
              onPressed: () => Navigator.pop(context, _name.text.trim()),
              child: const Text('Продолжить')),
        ],
      );
}

final class _SupportScreenState extends State<SupportScreen> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  final _message = TextEditingController();
  final _scroll = ScrollController();
  final _form = GlobalKey<FormState>();
  List<SupportTicket> _tickets = [];
  List<SupportMessage> _messages = [];
  SupportTicket? _selected;
  SupportException? _error;
  bool _available = false, _loading = true, _sending = false, _polling = false;
  int _generation = 0;
  Timer? _timer;
  String? _createRequest, _createContent, _sendRequest, _sendContent;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && !_loading && !_sending && !_polling) unawaited(_poll());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _subject.dispose();
    _description.dispose();
    _message.dispose();
    _scroll.dispose();
    super.dispose();
  }

  SupportException _safe(Object error) => error is SupportException
      ? error
      : const SupportException(SupportFailure.server);
  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final available = await widget.repository.available();
      final tickets = await widget.repository.tickets();
      if (!mounted || generation != _generation) return;
      setState(() {
        _available = available;
        _tickets = tickets;
        _loading = false;
      });
      final active =
          tickets.where((t) => t.status != SupportStatus.closed).firstOrNull;
      if (active != null) await _open(active);
    } on Object catch (e) {
      if (mounted && generation == _generation)
        setState(() {
          _error = _safe(e);
          _loading = false;
        });
    }
  }

  Future<void> _open(SupportTicket ticket) async {
    ++_generation;
    setState(() {
      _selected = ticket;
      _messages = [];
      _message.clear();
      _error = null;
    });
    await _poll();
    _toBottom();
  }

  Future<void> _poll() async {
    if (_polling) return;
    final generation = _generation;
    final selectedId = _selected?.id;
    _polling = true;
    try {
      final available = await widget.repository.available();
      final tickets = await widget.repository.tickets();
      if (!mounted || generation != _generation) return;
      setState(() {
        _available = available;
        _tickets = tickets;
      });
      if (selectedId != null) {
        var more = true;
        while (more) {
          final after = _messages.isEmpty ? 0 : _messages.last.id;
          final result =
              await widget.repository.thread(selectedId, after: after);
          if (!mounted || generation != _generation) return;
          final stick =
              !_scroll.hasClients || _scroll.position.extentAfter < 100;
          setState(() {
            _selected = result.ticket;
            final ids = _messages.map((m) => m.id).toSet();
            _messages = [
              ..._messages,
              ...result.messages.where((m) => !ids.contains(m.id))
            ];
            _error = null;
          });
          more = result.hasMore && result.messages.isNotEmpty;
          if (stick) _toBottom();
        }
      } else if (mounted) {
        setState(() => _error = null);
      }
    } on Object catch (e) {
      if (mounted && generation == _generation)
        setState(() => _error = _safe(e));
    } finally {
      _polling = false;
    }
  }

  Future<void> _create() async {
    if (_sending || !_available || !_form.currentState!.validate()) return;
    final guestName = await _askName();
    if (guestName == null || !mounted) return;
    final subject = _subject.text.trim(),
        description = _description.text.trim();
    final content = '$subject\n$description\n$guestName';
    if (_createContent != content) {
      _createRequest = supportRequestId();
      _createContent = content;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final thread = await widget.repository.create(
          requestId: _createRequest!,
          subject: subject,
          body: description,
          guestName: guestName);
      if (!mounted) return;
      ++_generation;
      setState(() {
        _selected = thread.ticket;
        _messages = thread.messages;
        _tickets = [
          thread.ticket,
          ..._tickets.where((t) => t.id != thread.ticket.id)
        ];
        _subject.clear();
        _description.clear();
        _createRequest = null;
        _createContent = null;
      });
      _toBottom();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _safe(e));
      if (e is SupportException && e.failure == SupportFailure.activeTicket)
        await _load();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String?> _askName() async {
    return showDialog<String>(
        context: context, builder: (_) => const _SupportNameDialog());
  }

  Future<void> _send() async {
    final body = _message.text.trim();
    final selected = _selected;
    if (_sending ||
        !_available ||
        body.isEmpty ||
        body.length > 2000 ||
        selected == null ||
        selected.status == SupportStatus.closed) return;
    if (_sendContent != body) {
      _sendRequest = supportRequestId();
      _sendContent = body;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await widget.repository
          .send(selected.id, requestId: _sendRequest!, body: body);
      if (!mounted) return;
      _message.clear();
      _sendRequest = null;
      _sendContent = null;
      await _poll();
      _toBottom();
    } on Object catch (e) {
      if (mounted) setState(() => _error = _safe(e));
      if (e is SupportException && e.failure == SupportFailure.closed)
        await _poll();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients)
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.support_agent, size: 30),
            const SizedBox(width: 12),
            Expanded(
                child: Text('Поддержка',
                    style: Theme.of(context).textTheme.headlineMedium)),
            IconButton(
                key: const Key('support-refresh'),
                onPressed: _loading || _sending || _polling
                    ? null
                    : _selected == null
                        ? _load
                        : _poll,
                tooltip: 'Обновить',
                icon: const Icon(Icons.refresh)),
          ]),
          const SizedBox(height: 8),
          const Text(
              'Напишите о проблеме — ответ специалиста появится в этом чате.'),
          const SizedBox(height: 16),
          if (_error != null)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const Icon(Icons.info_outline),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Text(_error!.message,
                              key: const Key('support-error'))),
                      if (_error!.failure == SupportFailure.signIn &&
                          widget.onOpenAccount != null)
                        TextButton(
                            onPressed: widget.onOpenAccount,
                            child: const Text('Открыть аккаунт')),
                    ]))),
          if (!_available && !_loading && _error == null)
            const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                    'Поддержка пока недоступна. История обращений сохранена.')),
          Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : LayoutBuilder(builder: (context, size) {
                      final narrow = size.maxWidth < 850;
                      if (narrow)
                        return _selected == null
                            ? _newAndHistory()
                            : _chat(back: true);
                      return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(width: 250, child: _history()),
                            const SizedBox(width: 16),
                            Expanded(
                                child:
                                    _selected == null ? _newTicket() : _chat()),
                          ]);
                    })),
        ]),
      );

  Widget _newAndHistory() => _tickets.isEmpty
      ? _newTicket()
      : Column(children: [
          SizedBox(height: 110, child: _history()),
          Expanded(child: _newTicket()),
        ]);

  Widget _history() => Card(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: OutlinedButton.icon(
                key: const Key('support-new'),
                onPressed: _sending
                    ? null
                    : () {
                        final active = _tickets
                            .where((t) => t.status != SupportStatus.closed)
                            .firstOrNull;
                        if (active != null) {
                          unawaited(_open(active));
                          return;
                        }
                        ++_generation;
                        setState(() {
                          _selected = null;
                          _messages = [];
                          _error = null;
                        });
                      },
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('Новое обращение'))),
        Expanded(
            child: _tickets.isEmpty
                ? const Center(child: Text('Обращений пока нет'))
                : ListView(
                    children: _tickets
                        .map((t) => ListTile(
                              key: Key('support-ticket-${t.id}'),
                              selected: t.id == _selected?.id,
                              title: Text(t.subject,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: Text(t.status.label),
                              onTap: _sending ? null : () => _open(t),
                            ))
                        .toList())),
      ]));

  Widget _newTicket() => Card(
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Новое обращение',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 20),
                  TextFormField(
                      key: const Key('support-subject'),
                      controller: _subject,
                      enabled: !_sending,
                      maxLength: 120,
                      decoration: const InputDecoration(labelText: 'Тема'),
                      validator: (s) => s == null || s.trim().isEmpty
                          ? 'Укажите тему'
                          : null),
                  const SizedBox(height: 12),
                  TextFormField(
                      key: const Key('support-description'),
                      controller: _description,
                      enabled: !_sending,
                      minLines: 4,
                      maxLines: 7,
                      maxLength: 2000,
                      decoration: const InputDecoration(
                          labelText: 'Описание проблемы',
                          alignLabelWithHint: true,
                          hintText:
                              'Что произошло и какие действия привели к проблеме?'),
                      validator: (s) => s == null || s.trim().isEmpty
                          ? 'Опишите проблему'
                          : null),
                  const SizedBox(height: 12),
                  const Text(
                      'Не отправляйте полный код активации, пароли и VPN-конфигурации. Сообщения будут переданы специалисту поддержки через Telegram.',
                      style: TextStyle(fontSize: 12)),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                      key: const Key('support-create'),
                      onPressed: _available && !_sending ? _create : null,
                      icon: const Icon(Icons.send_outlined),
                      label: Text(
                          _sending ? 'Отправляем…' : 'Отправить обращение')),
                ]),
          )));

  Widget _chat({bool back = false}) {
    final ticket = _selected!;
    final closed = ticket.status == SupportStatus.closed;
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [
                    if (back)
                      IconButton(
                          onPressed: _sending
                              ? null
                              : () {
                                  ++_generation;
                                  setState(() {
                                    _selected = null;
                                    _messages = [];
                                  });
                                },
                          tooltip: 'К обращениям',
                          icon: const Icon(Icons.arrow_back)),
                    Expanded(
                        child: Text(ticket.subject,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge)),
                  ]),
                  const SizedBox(height: 8),
                  Wrap(
                      spacing: 12,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Chip(
                            key: const Key('support-status'),
                            avatar: Icon(
                                closed
                                    ? Icons.check_circle_outline
                                    : Icons.schedule,
                                size: 18),
                            label: Text(ticket.status.label)),
                        Text('№${ticket.id.substring(0, 8)}',
                            style: Theme.of(context).textTheme.bodySmall),
                      ]),
                  const Divider(),
                  Expanded(
                      child: ListView.builder(
                          key: const Key('support-messages'),
                          controller: _scroll,
                          itemCount: _messages.length,
                          itemBuilder: (context, index) =>
                              _bubble(_messages[index]))),
                  const SizedBox(height: 12),
                  if (closed)
                    OutlinedButton.icon(
                        key: const Key('support-reopen-form'),
                        onPressed: () {
                          ++_generation;
                          setState(() {
                            _selected = null;
                            _messages = [];
                          });
                        },
                        icon: const Icon(Icons.add_comment_outlined),
                        label: const Text('Обращение закрыто · Создать новое'))
                  else
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Expanded(
                          child: TextField(
                              key: const Key('support-message'),
                              controller: _message,
                              enabled: !_sending,
                              minLines: 1,
                              maxLines: 4,
                              maxLength: 2000,
                              decoration: const InputDecoration(
                                  hintText: 'Напишите сообщение…'))),
                      const SizedBox(width: 8),
                      IconButton.filled(
                          key: const Key('support-send'),
                          onPressed: _sending || !_available ? null : _send,
                          tooltip: 'Отправить',
                          icon: _sending
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.send)),
                    ]),
                ])));
  }

  Widget _bubble(SupportMessage message) {
    final system = message.author == 'system';
    final mine = message.author == 'user';
    final scheme = Theme.of(context).colorScheme;
    final date = message.createdAt.toLocal();
    return Align(
        alignment: system
            ? Alignment.center
            : mine
                ? Alignment.centerRight
                : Alignment.centerLeft,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: system
                  ? Colors.transparent
                  : mine
                      ? scheme.primary.withValues(alpha: .15)
                      : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14)),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!system)
              Text(mine ? 'Вы' : 'Технический эксперт',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: scheme.primary)),
            SelectableText(message.body),
            const SizedBox(height: 4),
            Text(
                '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')} · ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}',
                style: Theme.of(context).textTheme.labelSmall),
          ]),
        ));
  }
}
