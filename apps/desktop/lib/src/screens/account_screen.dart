import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';
import '../infrastructure/windows_profile_provisioner.dart';

final class AccountScreen extends StatefulWidget {
  const AccountScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

final class _AccountScreenState extends State<AccountScreen> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _keyController = TextEditingController();
  AccountSession? _session;
  bool _loading = true;
  bool _submitting = false;
  bool _entryVisible = false;
  String? _revealedKey;
  String? _safeError;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  @override
  void dispose() {
    _keyController
      ..clear()
      ..dispose();
    _revealedKey = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(KenaiSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Аккаунт',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                if (widget.dependencies.accountRepository.isMock)
                  const _MockAccountBadge(),
              ],
            ),
            const SizedBox(height: KenaiSpacing.lg),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _session == null
                      ? _buildActivation()
                      : _buildAccount(_session!),
            ),
          ],
        ),
      );

  Widget _buildActivation() => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(KenaiSpacing.xxl),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    const Icon(Icons.key_outlined, size: 48),
                    const SizedBox(height: KenaiSpacing.md),
                    Text(
                      'Активация Kenai VPN',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: KenaiSpacing.sm),
                    const Text(
                      'Введите персональный ключ из 12 цифр.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: KenaiSpacing.lg),
                    TextFormField(
                      key: const Key('activation-key-input'),
                      controller: _keyController,
                      obscureText: !_entryVisible,
                      enableSuggestions: false,
                      autocorrect: false,
                      keyboardType: TextInputType.number,
                      autofillHints: const <String>[],
                      inputFormatters: <TextInputFormatter>[
                        _ActivationKeyFormatter(),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Персональный ключ',
                        prefixIcon: const Icon(Icons.password),
                        suffixIcon: IconButton(
                          key: const Key('toggle-key-entry'),
                          tooltip:
                              _entryVisible ? 'Скрыть ключ' : 'Показать ключ',
                          onPressed: () =>
                              setState(() => _entryVisible = !_entryVisible),
                          icon: Icon(
                            _entryVisible
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                          ),
                        ),
                      ),
                      validator: _validateKey,
                      onChanged: (_) {
                        if (_safeError != null) {
                          setState(() => _safeError = null);
                        }
                      },
                      onFieldSubmitted: (_) => _activate(),
                    ),
                    if (_safeError != null) ...<Widget>[
                      const SizedBox(height: KenaiSpacing.md),
                      Text(
                        _safeError!,
                        key: const Key('activation-error'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: KenaiSpacing.lg),
                    FilledButton.icon(
                      key: const Key('activate-account'),
                      onPressed: _submitting ? null : _activate,
                      icon: _submitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.lock_open_outlined),
                      label: Text(_submitting ? 'Проверяем…' : 'Активировать'),
                    ),
                    const SizedBox(height: KenaiSpacing.md),
                    Text(
                      'Ключ и VPN-реквизиты сохраняются в защищённом хранилище ОС.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  Widget _buildAccount(AccountSession session) {
    final _SubscriptionCopy copy = _subscriptionCopy(session.subscription);
    return ListView(
      children: <Widget>[
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(KenaiSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      const CircleAvatar(
                        radius: 25,
                        child: Icon(Icons.person_outline),
                      ),
                      const SizedBox(width: KenaiSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              session.account.email ?? 'Аккаунт Kenai VPN',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            Text('ID: ${session.account.id}'),
                          ],
                        ),
                      ),
                      _SubscriptionBadge(copy: copy),
                    ],
                  ),
                  const SizedBox(height: KenaiSpacing.xxl),
                  Text(
                    'Персональный ключ',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: KenaiSpacing.sm),
                  Container(
                    padding: const EdgeInsets.all(KenaiSpacing.md),
                    decoration: BoxDecoration(
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(KenaiRadii.control),
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: SelectableText(
                            _revealedKey ?? session.activationKeyMask,
                            key: const Key('stored-activation-key'),
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          key: const Key('reveal-stored-key'),
                          tooltip: _revealedKey == null
                              ? 'Показать ключ'
                              : 'Скрыть ключ',
                          onPressed: _toggleStoredKey,
                          icon: Icon(
                            _revealedKey == null
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                        IconButton(
                          key: const Key('copy-stored-key'),
                          tooltip: 'Копировать ключ',
                          onPressed: _copyStoredKey,
                          icon: const Icon(Icons.copy_outlined),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: KenaiSpacing.xxl),
                  Text(
                    'Подписка',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: KenaiSpacing.sm),
                  _InfoRow(label: 'Статус', value: copy.label),
                  _InfoRow(
                    label: 'Действует до',
                    value: _dateLabel(session.subscription.expiresAt),
                  ),
                  _InfoRow(
                    label: 'Тариф',
                    value: session.subscription.planName,
                  ),
                  const SizedBox(height: KenaiSpacing.xxl),
                  OutlinedButton.icon(
                    key: const Key('sign-out'),
                    onPressed: _confirmSignOut,
                    icon: const Icon(Icons.logout),
                    label: const Text('Выйти и удалить локальные данные'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  String? _validateKey(String? value) {
    try {
      ActivationKey.parse(value ?? '');
      return null;
    } on FormatException {
      return 'Ключ должен содержать ровно 12 цифр.';
    }
  }

  Future<void> _restore() async {
    try {
      final AccountSession? session =
          await widget.dependencies.accountRepository.restoreSession();
      if (!mounted) return;
      setState(() {
        _session = session;
        _loading = false;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _safeError = 'Не удалось открыть защищённое хранилище.';
      });
    }
  }

  Future<void> _activate() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    final ActivationKey activationKey =
        ActivationKey.parse(_keyController.text);
    setState(() {
      _submitting = true;
      _safeError = null;
    });
    try {
      final AccountSession session =
          await widget.dependencies.accountRepository.activate(activationKey);
      _keyController.clear();
      if (!mounted) return;
      setState(() {
        _session = session;
        _submitting = false;
        _entryVisible = false;
      });
    } on AccountApiException catch (error) {
      _keyController.clear();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _entryVisible = false;
        _safeError = _apiErrorCopy(error.failure);
      });
    } on ProfileProvisioningException catch (error) {
      _keyController.clear();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _entryVisible = false;
        _safeError = switch (error.code) {
          'SERVICE_UNAVAILABLE' ||
          'SERVICE_TIMEOUT' =>
            'Служба Kenai VPN не отвечает. Перезагрузите компьютер и повторите попытку.',
          _ => 'Служба Kenai VPN не смогла сохранить VPN-профиль.',
        };
      });
    } on Object {
      _keyController.clear();
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _entryVisible = false;
        _safeError =
            'Не удалось сохранить данные безопасно. Повторите попытку.';
      });
    }
  }

  Future<void> _toggleStoredKey() async {
    if (_revealedKey != null) {
      setState(() => _revealedKey = null);
      return;
    }
    try {
      final String? value =
          await widget.dependencies.accountRepository.revealActivationKey();
      if (!mounted) return;
      if (value == null) {
        _showMessage('Ключ не найден в защищённом хранилище.');
        return;
      }
      setState(() => _revealedKey = value);
    } on Object {
      if (mounted) _showMessage('Не удалось открыть защищённое хранилище.');
    }
  }

  Future<void> _copyStoredKey() async {
    try {
      final String? value =
          await widget.dependencies.accountRepository.revealActivationKey();
      if (value == null) {
        if (mounted) _showMessage('Ключ не найден в защищённом хранилище.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) _showMessage('Ключ скопирован.');
    } on Object {
      if (mounted) _showMessage('Не удалось скопировать ключ.');
    }
  }

  Future<void> _confirmSignOut() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Выйти из аккаунта?'),
            content: const Text(
              'Персональный ключ, локальная сессия и VPN-реквизиты будут удалены с этого устройства.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Отмена'),
              ),
              FilledButton(
                key: const Key('confirm-sign-out'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Выйти'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    await _signOut();
  }

  Future<void> _signOut() async {
    bool vpnStopped = true;
    try {
      final VpnConnectionState state =
          await widget.dependencies.vpnEngine.status();
      if (state.phase == VpnConnectionPhase.connected ||
          state.phase == VpnConnectionPhase.reconnecting) {
        await widget.dependencies.vpnEngine.disconnect(
          operationId: 'account-sign-out',
        );
      } else if (state.phase != VpnConnectionPhase.disconnected) {
        vpnStopped = false;
      }
    } on Object {
      vpnStopped = false;
    }
    if (!vpnStopped) {
      if (mounted) {
        _showMessage(
          'Не удалось безопасно остановить VPN. Данные аккаунта сохранены; повторите выход.',
        );
      }
      return;
    }
    try {
      await widget.dependencies.accountRepository.signOut();
      if (!mounted) return;
      setState(() {
        _session = null;
        _revealedKey = null;
        _safeError = null;
      });
      _showMessage('Локальные данные аккаунта удалены.');
    } on Object {
      if (mounted) {
        _showMessage('Не удалось удалить локальные данные. Повторите попытку.');
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

final class _ActivationKeyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) =>
      RegExp(r'^\d{0,12}$').hasMatch(newValue.text) ? newValue : oldValue;
}

final class _MockAccountBadge extends StatelessWidget {
  const _MockAccountBadge();

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(
          horizontal: KenaiSpacing.md,
          vertical: KenaiSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: KenaiTheme.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(KenaiRadii.control),
        ),
        child: const Text('Mock API'),
      );
}

final class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: KenaiSpacing.sm),
        child: Row(
          children: <Widget>[
            Expanded(child: Text(label)),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
      );
}

final class _SubscriptionCopy {
  const _SubscriptionCopy(this.label, this.color);

  final String label;
  final Color color;
}

final class _SubscriptionBadge extends StatelessWidget {
  const _SubscriptionBadge({required this.copy});

  final _SubscriptionCopy copy;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('subscription-status'),
        padding: const EdgeInsets.symmetric(
          horizontal: KenaiSpacing.md,
          vertical: KenaiSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: copy.color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(99),
        ),
        child: Text(copy.label),
      );
}

_SubscriptionCopy _subscriptionCopy(Subscription subscription) =>
    switch (subscription.status) {
      SubscriptionStatus.active =>
        const _SubscriptionCopy('Активна', KenaiTheme.success),
      SubscriptionStatus.expired =>
        const _SubscriptionCopy('Истекла', KenaiTheme.danger),
      SubscriptionStatus.suspended =>
        const _SubscriptionCopy('Приостановлена', KenaiTheme.warning),
    };

String _apiErrorCopy(AccountApiFailure failure) => switch (failure) {
      AccountApiFailure.invalidKey =>
        'Ключ не принят. Проверьте цифры или состояние подписки.',
      AccountApiFailure.noNetwork =>
        'Нет подключения к интернету. Проверьте сеть и повторите попытку.',
      AccountApiFailure.rateLimited =>
        'Слишком много попыток. Подождите немного и повторите.',
      AccountApiFailure.deviceLimit =>
        'Достигнут лимит устройств для этого ключа. Удалите старое устройство в панели.',
      AccountApiFailure.server =>
        'Сервис активации временно недоступен. Повторите позже.',
    };

String _dateLabel(DateTime? date) {
  if (date == null) return 'Не указано';
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(date.day)}.${twoDigits(date.month)}.${date.year}';
}
