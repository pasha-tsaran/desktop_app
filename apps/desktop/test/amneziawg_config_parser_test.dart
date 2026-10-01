import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/amneziawg_config_parser.dart';
import 'package:kenai_vpn_desktop/src/infrastructure/wireguard_config_parser.dart';

void main() {
  final String privateKey = base64Encode(List<int>.filled(32, 7));
  final String publicKey = base64Encode(List<int>.filled(32, 9));
  final String headerKey = base64Encode(List<int>.filled(32, 11));

  String profile({String extra = ''}) => '''
[Interface]
PrivateKey = $privateKey
Address = 10.8.0.2/32
DNS = 1.1.1.1
Jc = 4
Jmin = 64
Jmax = 128
S1 = 1
S2 = 2
S3 = 3
S4 = 4
H1 = 100
H2 = 200-210
H3 = 300
H4 = 400
$extra
[Peer]
PublicKey = $publicKey
Endpoint = vpn.example.test:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

  test('parses the bounded AmneziaWG 2.0 extension fields', () {
    final AmneziaWgProvisioningProfile parsed =
        const AmneziaWgConfigParser().parse(profile(extra: 'I1 = <b 0x01>'));
    expect(parsed.jc, 4);
    expect(parsed.jmin, 64);
    expect(parsed.jmax, 128);
    expect(parsed.h2, '200-210');
    expect(parsed.specialJunk, <String>['<b 0x01>']);
    expect(parsed.toString(), isNot(contains(privateKey)));
  });

  test('parses AmneziaWG 3.1 fields without exposing the header key', () {
    final String source = profile(
      extra: '''
MTU = 1376
HeaderProtectionKey = $headerKey
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on
''',
    )
        .replaceFirst('S1 = 1', 'S1 = 12')
        .replaceFirst('S2 = 2', 'S2 = 12')
        .replaceFirst('S3 = 3', 'S3 = 12')
        .replaceFirst('S4 = 4', 'S4 = 12');
    final AmneziaWgProvisioningProfile parsed =
        const AmneziaWgConfigParser().parse(source);
    expect(parsed.headerProtectionKey, hasLength(32));
    expect(parsed.contentPaddingAddition, '10-100');
    expect(parsed.randomTrailers, isTrue);
    expect(parsed.disableCookies, isTrue);
    expect(parsed.mtu, 1376);
    expect(parsed.toString(), isNot(contains(headerKey)));
  });

  test('accepts the small positive junk range used by AWG 3.1', () {
    final AmneziaWgProvisioningProfile parsed =
        const AmneziaWgConfigParser().parse(
      profile()
          .replaceFirst('Jmin = 64', 'Jmin = 10')
          .replaceFirst('Jmax = 128', 'Jmax = 50'),
    );
    expect(parsed.jmin, 10);
    expect(parsed.jmax, 50);
  });

  test('rejects missing, duplicate, out-of-range and injected fields', () {
    final AmneziaWgConfigParser parser = const AmneziaWgConfigParser();
    for (final String invalid in <String>[
      profile().replaceFirst('Jc = 4\n', ''),
      profile(extra: 'Jc = 5'),
      profile().replaceFirst('Jmin = 64', 'Jmin = 0'),
      profile().replaceFirst('Jmin = 64', 'Jmin = 1025'),
      profile().replaceFirst('H1 = 100', 'H1 = 200-100'),
      profile(extra: 'PostUp = calc.exe'),
      profile(extra: 'I2 = gap'),
      profile(extra: 'RandomTrailers = maybe'),
      profile(extra: 'ContentPaddingAddition = 1-70000'),
      profile(extra: 'MTU = 575'),
      profile(extra: 'MTU = 9001'),
    ]) {
      expect(
        () => parser.parse(invalid),
        throwsA(isA<WireGuardConfigException>()),
      );
    }
  });
}
