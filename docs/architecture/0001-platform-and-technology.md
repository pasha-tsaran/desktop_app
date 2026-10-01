# ADR 0001: целевая платформа и технологии

- Статус: принято владельцем
- Дата: 2026-09-05
- Первый релиз: Windows 10/11 x64
- Будущие платформы: Android, iOS и macOS

## Критерий решения

Главный критерий — безопасная системная VPN-интеграция. Переиспользование UI
полезно, но не может заменить отдельный системный адаптер для каждой ОС.

## Сравнение вариантов

| Вариант | Системная интеграция Windows | Переносимость | Основной риск | Решение |
| --- | --- | --- | --- | --- |
| .NET + WinUI/WPF + C++/Rust service | Отличная | UI почти только Windows | Отдельный UI для мобильных и macOS | Не выбран |
| Qt 6 + C++ | Отличная | Высокая для desktop, средняя для mobile | Большая C++-поверхность в привилегированном коде | Не выбран |
| Tauri + Rust | Хорошая для desktop | Средняя | WebView не решает Network Extension/VpnService, mobile сложнее | Не выбран |
| Flutter/Dart + Rust service/core | Хорошая при нативном service boundary | Высокая для presentation/domain | Нативные VPN-адаптеры всё равно нужны | Выбран |

Flutter выбран для presentation, навигации и непривилегированной application
логики. Rust выбран для строгих контрактов, конечного автомата и будущей
Windows-службы. Выбор не предполагает, что Flutter-плагин будет управлять
драйверами, маршрутами или firewall.

## Реальная поддержка протоколов на Windows

- **WireGuard:** официальный WireGuardNT поддерживает Windows 10/11 и
  AMD64/x86/ARM64. Для встраивания официальный проект направляет разработчиков
  к embeddable tunnel service. Адаптер должен использовать проверенные,
  подписанные и закреплённые по версии артефакты.
- **AmneziaWG 2.0:** официальный AmneziaWG Windows client использует Wintun и
  объявлен проектом Amnezia как рекомендуемый Windows-клиент. Это отдельный
  адаптер; ABI-совместимость с WireGuardNT не предполагается.
- **VLESS + REALITY:** официальный Xray-core поддерживает REALITY и сборку под
  Windows. Его TUN-реализация на Windows использует Wintun, но настройка
  маршрутов и предотвращение routing loop остаются обязанностью системного
  слоя Kenai.
- **Kill switch:** планируется через Windows Filtering Platform (WFP), где
  фильтры создаются транзакционно и принадлежат будущей системной службе.
- **Tray/autostart:** это функция непривилегированного UI-процесса. Автозапуск
  не должен запускать GUI от администратора.
- **Защищённое хранилище:** пользовательские секреты — DPAPI CurrentUser или
  Credential Manager. Короткие credentials могут храниться в Credential
  Manager, а большие profile blobs — в DPAPI-зашифрованных файлах с user-only
  ACL. Если службе понадобится постоянный секрет — отдельное хранилище DPAPI
  LocalMachine с service-specific ACL.

Архитектурное решение не является разрешением включать эти интеграции на
этапе 1. Перед production-реализацией каждому engine binary/driver нужен
отдельный обзор лицензии, цепочки поставки, подписи, обновления и rollback.

Kill switch нельзя считать готовым только потому, что создано WFP-правило.
Будущий этап обязан определить recovery после crash/reboot, исключения только
для VPN endpoint и необходимых системных служб, порядок включения до маршрута,
атомарный rollback и leak-тесты IPv4, IPv6 и DNS. До прохождения этих тестов
переключатель в production UI не появляется.

## Границы привилегий

```text
обычный пользователь
  Flutter UI
    -> application use case
      -> VpnEngine port
        -> versioned typed IPC
          -> Windows service (минимально необходимые права)
            -> WireGuard adapter | AmneziaWG adapter | Xray adapter
            -> routes | DNS | WFP kill switch
```

UI никогда не принимает и не передаёт произвольные команды, пути к бинарникам
или shell-фрагменты. Локальный IPC для Windows — named pipe с явным DACL,
запретом удалённого доступа, проверкой клиента, версии контракта и allowlist
операций. Дефолтный ACL named pipe использовать нельзя: Microsoft указывает,
что он в том числе даёт read-доступ Everyone и anonymous.

Служба является источником истины для `CONNECTED`, активности kill switch,
статистики и состояния системного туннеля. UI показывает состояние только
после подтверждённого события службы.

## Потоки данных

### Активация

```text
12-значный ключ -> ApiClient -> HTTPS server API -> typed response validation
  -> SecureStorage -> non-secret domain references -> UI
```

Ключ и VPN-реквизиты не попадают в логи, analytics, exception text или
обычное состояние UI. После получения ответ валидируется до записи в
хранилище. TLS certificate validation обязательна.

### Подключение

```text
UI intent -> application lock -> subscription decision -> VpnProfile handle
  -> VpnEngine -> service validation -> engine adapter -> OS confirmation
  -> state event -> application -> UI
```

Секреты расшифровываются на минимальное время. Служба получает только
типизированный профиль/операцию; данные редактируются до диагностики.
Конфликтующие connect/disconnect сериализуются одним application lock и
повторно отклоняются конечным автоматом службы.

### Диагностика

```text
UI consent -> collectors -> redaction -> preview of categories -> ZIP export
```

Редактирование выполняется до отображения и до сериализации архива.

## Добавление Android, iOS и macOS

Общий Dart domain/application слой и большая часть UI переиспользуются.
Системный слой не переиспользуется напрямую:

| Платформа | Обязательный системный адаптер | Оценка |
| --- | --- | --- |
| Android | Kotlin `VpnService`, foreground service, Keystore | Средняя сложность |
| macOS | Swift Network Extension + Keychain | Средняя/высокая |
| iOS | Swift Packet Tunnel Network Extension + entitlement + Keychain | Высокая |

На iOS сложность выше из-за отдельного extension target, entitlement,
ограничений жизненного цикла/памяти и проверки распространения. Поэтому
Windows-first не блокирует другие ОС, но и не превращает их в простую
пересборку Flutter-приложения.

## Первичные источники

- [Flutter: supported deployment platforms](https://docs.flutter.dev/reference/supported-platforms)
- [WireGuardNT](https://git.zx2c4.com/wireguard-nt/about/)
- [WireGuard embeddable tunnel service](https://git.zx2c4.com/wireguard-windows/tree/embeddable-dll-service/README.md)
- [AmneziaWG Windows client](https://github.com/amnezia-vpn/amneziawg-windows-client)
- [AmneziaWG Go platform notes](https://github.com/amnezia-vpn/amneziawg-go)
- [Xray-core](https://github.com/XTLS/Xray-core)
- [Xray TUN notes](https://github.com/XTLS/Xray-core/blob/main/proxy/tun/README.md)
- [Microsoft: Windows Filtering Platform](https://learn.microsoft.com/en-us/windows/win32/fwp/windows-filtering-platform-start-page)
- [Microsoft: named pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [Microsoft: DPAPI example and scope](https://learn.microsoft.com/en-us/windows/win32/seccrypto/example-c-program-using-cryptprotectdata)
- [Android: VpnService](https://developer.android.com/reference/android/net/VpnService)
- [Android: Keystore](https://developer.android.com/privacy-and-security/keystore)
- [Apple: NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)
- [Apple: Keychain services](https://developer.apple.com/documentation/security/keychain-services)
