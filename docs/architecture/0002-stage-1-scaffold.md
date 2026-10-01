# ADR 0002: каркас этапа 1

- Статус: принято
- Дата: 2026-09-05

## Решение

Этап 1 проверяет границы модулей, контракты, конечный автомат и навигацию без
production API, оплаты и системного VPN.

```text
apps/desktop -> packages/kenai_ui
apps/desktop -> packages/kenai_core <- mock adapters

services/windows_vpn_service -> crates/vpn_service_core
                             -> crates/vpn_contracts
proto/kenai_vpn_service.proto -----^ (будущий generated transport)
```

- `kenai_core/domain` содержит Account, Subscription, VpnServer,
  ServerStatus-поля, Device, VpnProtocol, VpnProfile, ConnectionSession,
  DiagnosticEvent, Tariff и AppSettings.
- `kenai_core/ports` содержит ApiClient, SecureStorage, VpnEngine,
  ServerRepository, SubscriptionRepository, PaymentProvider и
  DiagnosticExporter.
- `kenai_core/mocks` предоставляет детерминированные реализации без сети,
  оплаты, драйверов, маршрутов, DNS или firewall.
- `kenai_ui` содержит только темы и общие UI-примитивы.
- `apps/desktop/lib/bootstrap.dart` — единственный composition root UI.
- Rust service executable на этом этапе — непривилегированный placeholder.

`VpnEngine` предоставляет единый контракт: `connect`, `disconnect`, `status`,
`statistics`, `validateProfile`, `collectDiagnostics` и поток состояний.
Каждый `VpnProfile` — отдельная комбинация device/server/protocol и содержит
только безопасные идентификаторы; реквизиты должны жить в SecureStorage.

## Конечный автомат

Общий словарь Dart, protobuf и Rust:

```text
DISCONNECTED -> VALIDATING -> CONNECTING -> CONNECTED
CONNECTED -> RECONNECTING -> CONNECTED
CONNECTED|RECONNECTING -> DISCONNECTING -> DISCONNECTED

failure states:
BLOCKED_BY_SUBSCRIPTION | NO_NETWORK | SERVER_UNAVAILABLE | ERROR
```

Одновременные конфликтующие connect/disconnect отклоняются. В mock-движке и
чистом Rust core есть тесты жизненного цикла и блокировки параллельных команд.

## Осознанные ограничения

- Flutter Windows runner сгенерирован стандартным `flutter create`; скрипт
  `tool/bootstrap-windows.ps1` может восстановить его и не добавляет VPN-код.
- Protobuf-код пока не генерируется: схема и dependency-free Rust типы позволяют
  проверить контракт до выбора IPC-библиотеки.
- Mock подключение меняет только состояние в памяти и явно помечено в UI.
- Единственный текущий mock-сервер — Армения; модель с первого дня является
  списком и поддерживает будущие страны.
- Production-адаптеры могут появиться только отдельным согласованным этапом.
