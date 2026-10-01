import 'package:flutter/material.dart';

enum AppDestination {
  servers('Серверы', Icons.public_outlined, Icons.public),
  account('Аккаунт', Icons.person_outline, Icons.person),
  plans('Тарифы', Icons.credit_card_outlined, Icons.credit_card),
  vpnSettings('Настройки VPN', Icons.settings_outlined, Icons.settings),
  statistics('Статистика', Icons.monitor_heart_outlined, Icons.monitor_heart),
  logs('Логи', Icons.article_outlined, Icons.article),
  speedTest('Тест скорости', Icons.speed_outlined, Icons.speed),
  settings('Параметры', Icons.tune_outlined, Icons.tune),
  support('Поддержка', Icons.support_agent, Icons.support_agent);

  const AppDestination(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  String? get imageAsset => switch (this) {
        servers ||
        account ||
        logs ||
        vpnSettings ||
        settings ||
        support =>
          'assets/branding/$name.png',
        _ => null,
      };
}
