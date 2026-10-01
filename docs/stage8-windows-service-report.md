# Отчёт этапа 8 — Windows-служба и IPC

## Реализовано

- Windows SCM lifecycle: регистрация, `Running`, обработка `Stop`, `Stopped`;
- локальный named pipe с explicit protected DACL, запретом remote clients,
  single-instance guard и проверкой client PID/session;
- бинарный contract v1 с кадрами до 16 KiB и командами `status`, `connect`,
  `disconnect`, `diagnostics`;
- allowlist для request/profile/operation IDs, исключающая пути и shell-текст;
- типизированный безопасный ответ без platform error text;
- защита от повторного request ID и пересекающихся операций;
- `Connect` не имитирует VPN: возвращает `ENGINE_NOT_INSTALLED`;
- dev install/uninstall PowerShell-скрипты с `ShouldProcess`, elevation check и
  без автоматической установки или запуска.

## Границы этапа

VPN-драйверы, маршруты, DNS, WFP, реальные профили и production API не
подключены. GUI пока не переключён с `MockVpnEngine` на IPC-клиент. Это будет
делаться только вместе с реальным WireGuard-адаптером и проверкой profile
ownership. RDP/Fast User Switching требуют расширения session/SID policy до
production.

## Quality gate

- `cargo fmt --all --check` — пройден;
- `cargo clippy --workspace --all-targets -- -D warnings` — пройден;
- `cargo test --workspace` — 12 тестов пройдено;
- release-сборка Windows-службы — пройдена;
- синтаксическая проверка двух dev PowerShell-скриптов — пройдена;
- `dart analyze .` — замечаний нет;
- `flutter test packages/kenai_core` — 29 тестов пройдено;
- `flutter test apps/desktop` — 23 теста пройдено;
- `flutter build windows --release` — пройдена.
