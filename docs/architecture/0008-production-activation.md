# Production-активация WireGuard-first MVP — этап 9

## Серверный контракт

Клиент использует только уже существующий `POST /api/v1/activate` с телом
`{"activation_key":"<12 цифр>"}`. Реализация сервера проверяет активный аккаунт,
неистёкшую подписку и наличие трёх профилей, после чего возвращает `account` и
`protocols`. Серверный проект не изменялся.

Первый MVP сохраняет только `protocols.wireguard`. Возвращаемые сервером
AmneziaWG и VLESS значения намеренно игнорируются и не записываются локально.
Успешный `200` означает active subscription на момент проверки. Текущий контракт
не возвращает дату окончания, поэтому UI честно показывает её отсутствие.

## Transport boundary

`DartIoApiClient`:

- принимает только HTTPS base URL без credentials, query и fragment;
- разрешает только относительные пути `/api/...`;
- использует стандартную TLS-проверку ОС и не задаёт `badCertificateCallback`;
- имеет connection/request timeout;
- ограничивает ответ 256 KiB;
- принимает успешный ответ только как JSON object;
- не журналирует URL query, body, ответ или исключение ОС.

URL не является секретом и задаётся при сборке:

```powershell
flutter build windows --release --dart-define=KENAI_API_BASE_URL=https://api.example.com
```

Если URL отсутствует или невалиден, release использует fail-closed transport и
показывает безопасную ошибку сервера. HTTP и отключение проверки сертификата не
поддерживаются.

## Release composition

Development продолжает использовать детерминированные mocks. Release использует:

- `DartIoApiClient` или fail-closed `UnavailableApiClient`;
- `ProductionActivationApiClient`;
- `ArmeniaMvpServerRepository` только с WireGuard;
- `UnavailableVpnEngine` до этапа 11.

Поэтому текущая release-сборка уже не может имитировать успешный VPN. Настоящее
подключение появится после provisioning и WireGuard-этапов.

## Известные ограничения сервера

- ответ не содержит `subscription.expires_at`;
- нет session/refresh/logout endpoint;
- сервер всегда возвращает сразу три секретных профиля;
- нет отдельного server catalog или device registration API.

Эти ограничения не блокируют одноустройственный WireGuard-first MVP, но должны
быть устранены до многосерверной и многопротокольной версии.

## Quality gate

- Dart format и analyze — пройдены без замечаний;
- core tests — 32 пройдено;
- desktop/UI/API tests — 27 пройдено;
- Rust fmt, clippy `-D warnings` и 12 tests — пройдены;
- stage 1/7/9 boundary scripts — пройдены;
- Windows release с HTTPS `.invalid` URL — собран без сетевого обращения;
- mock-маркеры в release artifacts — не обнаружены.
