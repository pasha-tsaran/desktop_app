import 'dart:async';

import 'package:flutter/material.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_ui/kenai_ui.dart';

import '../../bootstrap.dart';

const List<Tariff> _tariffs = <Tariff>[
  Tariff(id: 'month-1', months: 1, priceRubles: 250),
  Tariff(id: 'month-3', months: 3, priceRubles: 750),
  Tariff(id: 'month-6', months: 6, priceRubles: 1500),
  Tariff(id: 'month-12', months: 12, priceRubles: 3000),
];

final class PlansScreen extends StatefulWidget {
  const PlansScreen({required this.dependencies, super.key});

  final AppDependencies dependencies;

  @override
  State<PlansScreen> createState() => _PlansScreenState();
}

final class _PlansScreenState extends State<PlansScreen> {
  late PaymentState _payment;
  late final StreamSubscription<PaymentState> _subscription;
  Tariff _selected = _tariffs.first;

  PaymentProvider get _provider => widget.dependencies.paymentProvider;

  @override
  void initState() {
    super.initState();
    _payment = _provider.currentState;
    _subscription = _provider.states.listen((PaymentState state) {
      if (mounted) setState(() => _payment = state);
    });
  }

  @override
  void dispose() {
    unawaited(_subscription.cancel());
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
                    'Тарифы',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                if (_provider.isMock) const _DevelopmentBadge(),
              ],
            ),
            const SizedBox(height: KenaiSpacing.sm),
            const Text('Единая цена — 250 ₽ за каждый месяц.'),
            const SizedBox(height: KenaiSpacing.lg),
            Expanded(
              child: ListView(
                children: <Widget>[
                  LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      final int columns = constraints.maxWidth >= 1000
                          ? 4
                          : constraints.maxWidth >= 560
                              ? 2
                              : 1;
                      final double width = (constraints.maxWidth -
                              (columns - 1) * KenaiSpacing.md) /
                          columns;
                      return Wrap(
                        spacing: KenaiSpacing.md,
                        runSpacing: KenaiSpacing.md,
                        children: _tariffs
                            .map(
                              (Tariff tariff) => SizedBox(
                                width: width,
                                child: _TariffCard(
                                  tariff: tariff,
                                  selected: tariff.id == _selected.id,
                                  enabled: !_isBusy,
                                  onSelected: () =>
                                      setState(() => _selected = tariff),
                                ),
                              ),
                            )
                            .toList(growable: false),
                      );
                    },
                  ),
                  const SizedBox(height: KenaiSpacing.xl),
                  _buildPaymentPanel(),
                ],
              ),
            ),
          ],
        ),
      );

  bool get _isBusy =>
      _payment.phase == PaymentPhase.creatingOrder ||
      _payment.phase == PaymentPhase.subscriptionUpdating;

  Widget _buildPaymentPanel() {
    final _PaymentCopy copy = _paymentCopy(_payment);
    final PaymentSession? session = _payment.session;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(KenaiSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(copy.icon, color: copy.color),
                const SizedBox(width: KenaiSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        copy.title,
                        key: const Key('payment-phase'),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(copy.message),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: KenaiSpacing.lg),
            if (!_provider.isAvailable) ...<Widget>[
              const Text(
                'Оплата пока недоступна: платёжный backend не подключён. Успешная оплата не симулируется.',
                key: Key('production-payment-unavailable'),
              ),
            ] else if (_payment.phase == PaymentPhase.awaitingPayment &&
                session != null) ...<Widget>[
              if (_provider.isMock)
                FilledButton.icon(
                  key: const Key('mock-confirm-payment'),
                  onPressed: () => _confirm(session.id),
                  icon: const Icon(Icons.developer_mode),
                  label: const Text('Симулировать подтверждение'),
                ),
              const SizedBox(height: KenaiSpacing.sm),
              TextButton(
                key: const Key('cancel-payment'),
                onPressed: () => _cancel(session.id),
                child: const Text('Отменить'),
              ),
            ] else ...<Widget>[
              FilledButton(
                key: const Key('buy-tariff'),
                onPressed: _isBusy ? null : () => _createOrder(_selected),
                child: Text(
                  'Выбрать: ${_selected.months} ${_monthsWord(_selected.months)} за ${_price(_selected.priceRubles)}',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _createOrder(Tariff tariff) async {
    try {
      await _provider.createCheckout(planId: tariff.id);
    } on PaymentException {
      if (mounted) _showSafeError();
    } on Object {
      if (mounted) _showSafeError();
    }
  }

  Future<void> _confirm(String sessionId) async {
    if (!_provider.isMock) return;
    try {
      final bool confirmed = await _provider.confirm(sessionId);
      if (!confirmed && mounted) _showSafeError();
    } on Object {
      if (mounted) _showSafeError();
    }
  }

  Future<void> _cancel(String sessionId) async {
    try {
      await _provider.cancel(sessionId);
    } on Object {
      if (mounted) _showSafeError();
    }
  }

  void _showSafeError() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content:
              Text('Операцию оплаты выполнить не удалось. Попробуйте позже.'),
        ),
      );
  }
}

final class _TariffCard extends StatelessWidget {
  const _TariffCard({
    required this.tariff,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final Tariff tariff;
  final bool selected;
  final bool enabled;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) => Card(
        key: Key('tariff-${tariff.months}'),
        color: selected ? Theme.of(context).colorScheme.primaryContainer : null,
        child: InkWell(
          onTap: enabled ? onSelected : null,
          borderRadius: BorderRadius.circular(KenaiRadii.card),
          child: Padding(
            padding: const EdgeInsets.all(KenaiSpacing.xl),
            child: Column(
              children: <Widget>[
                Text(
                  '${tariff.months} ${_monthsWord(tariff.months)}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: KenaiSpacing.md),
                Text(
                  _price(tariff.priceRubles),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: KenaiSpacing.xs),
                const Text('250 ₽ / месяц'),
              ],
            ),
          ),
        ),
      );
}

final class _DevelopmentBadge extends StatelessWidget {
  const _DevelopmentBadge();

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('mock-payment-badge'),
        padding: const EdgeInsets.symmetric(
          horizontal: KenaiSpacing.md,
          vertical: KenaiSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: KenaiTheme.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(KenaiRadii.control),
        ),
        child: const Text('Mock-оплата · Development'),
      );
}

final class _PaymentCopy {
  const _PaymentCopy(this.title, this.message, this.icon, this.color);

  final String title;
  final String message;
  final IconData icon;
  final Color color;
}

_PaymentCopy _paymentCopy(PaymentState state) => switch (state.phase) {
      PaymentPhase.idle => const _PaymentCopy(
          'Выберите период',
          'Заказ ещё не создан.',
          Icons.credit_card_outlined,
          KenaiTheme.accent,
        ),
      PaymentPhase.creatingOrder => const _PaymentCopy(
          'Создаём заказ',
          'Подготавливаем безопасную платёжную сессию.',
          Icons.hourglass_top,
          KenaiTheme.warning,
        ),
      PaymentPhase.awaitingPayment => const _PaymentCopy(
          'Ожидаем оплату',
          'Подписка обновится только после подтверждения сервера.',
          Icons.schedule,
          KenaiTheme.warning,
        ),
      PaymentPhase.paid => const _PaymentCopy(
          'Оплата подтверждена',
          'Сервер подтвердил платёж и обновление подписки.',
          Icons.check_circle_outline,
          KenaiTheme.success,
        ),
      PaymentPhase.cancelled => const _PaymentCopy(
          'Оплата отменена',
          'Заказ отменён, списание не подтверждено.',
          Icons.cancel_outlined,
          KenaiTheme.warning,
        ),
      PaymentPhase.failed => const _PaymentCopy(
          'Ошибка оплаты',
          'Платёж не подтверждён. Подписка не изменена.',
          Icons.error_outline,
          KenaiTheme.danger,
        ),
      PaymentPhase.subscriptionUpdating => const _PaymentCopy(
          'Обновляем подписку',
          'Проверяем новое состояние подписки на сервере.',
          Icons.sync,
          KenaiTheme.accent,
        ),
    };

String _monthsWord(int months) => months == 1 ? 'месяц' : 'месяцев';

String _price(int rubles) {
  final String digits = rubles.toString();
  final String grouped = digits.length > 3
      ? '${digits.substring(0, digits.length - 3)} ${digits.substring(digits.length - 3)}'
      : digits;
  return '$grouped ₽';
}
