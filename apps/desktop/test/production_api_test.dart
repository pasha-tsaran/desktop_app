import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/production_api.dart';

void main() {
  test('accepts only an HTTPS production API base URI', () {
    expect(
      validatedProductionApiBaseUri('https://api.kenai.example'),
      Uri.parse('https://api.kenai.example/'),
    );
    for (final String value in <String>[
      '',
      'http://api.kenai.example',
      'https://user:password@api.kenai.example',
      'https://api.kenai.example?debug=true',
      'not a uri',
    ]) {
      expect(validatedProductionApiBaseUri(value), isNull);
    }
  });

  test(
    'production activation imports VLESS and AmneziaWG for one device',
    () async {
      final _RecordingApiClient transport = _RecordingApiClient(
        response: const ApiResponse(
          statusCode: 200,
          body: <String, Object?>{
            'account': <String, Object?>{
              'id': 'account-1',
              'email': null,
              'telegram_username': 'kenai_user',
              'phone_number': null,
            },
            'protocols': <String, Object?>{
              'wireguard':
                  '[Interface]\nPrivateKey=fake\n[Peer]\nPublicKey=fake',
              'amneziawg': 'awg-secret',
              'vless': 'ignored-vless-secret',
            },
            'locations': <String, Object?>{
              'netherlands-1': <String, Object?>{
                'vless': 'nl-vless-secret',
                'amneziawg': 'nl-awg-secret',
              },
            },
            'subscription': <String, Object?>{
              'status': 'active',
              'expires_at': '2026-10-05T12:00:00Z',
              'device_limit': 32,
            },
          },
        ),
      );
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final ProductionActivationApiClient client =
          ProductionActivationApiClient(
            apiClient: transport,
            secureStorage: storage,
            now: () => DateTime.utc(2026, 9, 5, 12),
          );

      final ActivationResult result = await client.activate(
        ActivationKey.parse(_activationKey()),
      );

      expect(client.isMock, isFalse);
      expect(transport.request?.method, ApiMethod.post);
      expect(transport.request?.path, '/api/v1/activate');
      expect(transport.request?.body['activation_key'], _activationKey());
      expect(
        transport.request?.body['device_id'],
        matches(RegExp(r'^[a-f0-9]{32}$')),
      );
      expect(result.account.id, 'account-1');
      expect(result.subscription.status, SubscriptionStatus.active);
      expect(result.subscription.expiresAt, DateTime.utc(2026, 10, 5, 12));
      expect(result.subscription.deviceLimit, 32);
      expect(result.subscription.lastVerifiedAt, DateTime.utc(2026, 9, 5, 12));
      expect(result.vpnCredentials, <VpnProtocol, String>{
        VpnProtocol.vlessReality: 'ignored-vless-secret',
        VpnProtocol.amneziaWg: 'awg-secret',
      });
      expect(
        result.locationVlessCredentials['netherlands-1'],
        'nl-vless-secret',
      );
      expect(
        result.locationAmneziaWgCredentials['netherlands-1'],
        'nl-awg-secret',
      );
    },
  );

  test(
    'the same installation reuses its device ID with a shared key',
    () async {
      final InMemorySecureStorage storage = InMemorySecureStorage();
      final _RecordingApiClient firstTransport = _RecordingApiClient(
        response: const ApiResponse(
          statusCode: 200,
          body: <String, Object?>{
            'account': <String, Object?>{'id': 'account-1'},
            'protocols': <String, Object?>{'vless': 'profile-1'},
          },
        ),
      );
      await ProductionActivationApiClient(
        apiClient: firstTransport,
        secureStorage: storage,
      ).activate(ActivationKey.parse(_activationKey()));
      final _RecordingApiClient secondTransport = _RecordingApiClient(
        response: firstTransport.response,
      );
      await ProductionActivationApiClient(
        apiClient: secondTransport,
        secureStorage: storage,
      ).activate(ActivationKey.parse(_activationKey()));

      expect(
        secondTransport.request?.body['device_id'],
        firstTransport.request?.body['device_id'],
      );
    },
  );

  test('VLESS-only activation accepts disabled legacy protocols', () async {
    final _RecordingApiClient transport = _RecordingApiClient(
      response: const ApiResponse(
        statusCode: 200,
        body: <String, Object?>{
          'account': <String, Object?>{'id': 'account-1'},
          'protocols': <String, Object?>{
            'wireguard': null,
            'amneziawg': null,
            'vless': 'vless-profile',
          },
        },
      ),
    );
    final ProductionActivationApiClient client = ProductionActivationApiClient(
      apiClient: transport,
      secureStorage: InMemorySecureStorage(),
    );

    final ActivationResult result = await client.activate(
      ActivationKey.parse(_activationKey()),
    );

    expect(result.vpnCredentials, <VpnProtocol, String>{
      VpnProtocol.vlessReality: 'vless-profile',
    });
  });

  test('VLESS-only activation rejects a missing VLESS profile', () async {
    final ProductionActivationApiClient client = ProductionActivationApiClient(
      secureStorage: InMemorySecureStorage(),
      apiClient: _RecordingApiClient(
        response: const ApiResponse(
          statusCode: 200,
          body: <String, Object?>{
            'account': <String, Object?>{'id': 'account-1'},
            'protocols': <String, Object?>{
              'wireguard': null,
              'amneziawg': null,
              'vless': null,
            },
          },
        ),
      ),
    );

    await expectLater(
      client.activate(ActivationKey.parse(_activationKey())),
      throwsA(
        isA<AccountApiException>().having(
          (AccountApiException error) => error.failure,
          'failure',
          AccountApiFailure.server,
        ),
      ),
    );
  });

  test('activation maps safe HTTP and transport failures', () async {
    for (final ({int status, AccountApiFailure failure}) item
        in <({int status, AccountApiFailure failure})>[
          (status: 401, failure: AccountApiFailure.invalidKey),
          (status: 409, failure: AccountApiFailure.deviceLimit),
          (status: 429, failure: AccountApiFailure.rateLimited),
          (status: 503, failure: AccountApiFailure.server),
        ]) {
      final ProductionActivationApiClient client =
          ProductionActivationApiClient(
            secureStorage: InMemorySecureStorage(),
            apiClient: _RecordingApiClient(
              response: ApiResponse(
                statusCode: item.status,
                body: const <String, Object?>{},
              ),
            ),
          );
      await expectLater(
        client.activate(ActivationKey.parse(_activationKey())),
        throwsA(
          isA<AccountApiException>().having(
            (AccountApiException error) => error.failure,
            'failure',
            item.failure,
          ),
        ),
      );
    }

    final ProductionActivationApiClient offline = ProductionActivationApiClient(
      secureStorage: InMemorySecureStorage(),
      apiClient: const _FailingApiClient(ApiTransportFailure.noNetwork),
    );
    await expectLater(
      offline.activate(ActivationKey.parse(_activationKey())),
      throwsA(
        isA<AccountApiException>().having(
          (AccountApiException error) => error.failure,
          'failure',
          AccountApiFailure.noNetwork,
        ),
      ),
    );
  });

  test('malformed success response does not expose returned secrets', () async {
    final ProductionActivationApiClient client = ProductionActivationApiClient(
      secureStorage: InMemorySecureStorage(),
      apiClient: _RecordingApiClient(
        response: const ApiResponse(
          statusCode: 200,
          body: <String, Object?>{
            'account': <String, Object?>{'id': 'account-1'},
            'protocols': <String, Object?>{
              'wireguard': 'unused-legacy-profile',
              'amneziawg': 'awg-secret',
              'vless': null,
            },
          },
        ),
      ),
    );
    try {
      await client.activate(ActivationKey.parse(_activationKey()));
      fail('Expected a safe API error');
    } on AccountApiException catch (error) {
      expect(error.failure, AccountApiFailure.server);
      expect(error.toString(), isNot(contains('unused-legacy-profile')));
    }
  });
}

final class _RecordingApiClient implements ApiClient {
  _RecordingApiClient({required this.response});

  final ApiResponse response;
  ApiRequest? request;

  @override
  Future<ApiResponse> send(ApiRequest request) async {
    this.request = request;
    return response;
  }
}

final class _FailingApiClient implements ApiClient {
  const _FailingApiClient(this.failure);

  final ApiTransportFailure failure;

  @override
  Future<ApiResponse> send(ApiRequest request) =>
      throw ApiClientException(failure);
}

String _activationKey() => <String>['1234', '5678', '9012'].join();
