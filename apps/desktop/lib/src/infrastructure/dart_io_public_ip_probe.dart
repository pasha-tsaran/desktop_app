import 'dart:convert';
import 'dart:io';

import 'package:kenai_core/kenai_core.dart';

/// Uses the current OS route. Never changes proxy, DNS or VPN settings.
final class DartIoPublicIpProbe implements PublicIpProbe {
  const DartIoPublicIpProbe();

  @override
  Future<String?> measure() async {
    for (final endpoint in [
      'https://api.ipify.org',
      'https://ipv4.icanhazip.com'
    ]) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 4);
      try {
        final value = await (() async {
          final request = await client.getUrl(Uri.parse(endpoint));
          request.followRedirects = false;
          final response = await request.close();
          if (response.statusCode != 200) return null;
          final bytes = <int>[];
          await for (final chunk in response) {
            bytes.addAll(chunk);
            if (bytes.length > 128) return null;
          }
          final text = utf8.decode(bytes).trim();
          final address = InternetAddress.tryParse(text);
          return address?.type == InternetAddressType.IPv4
              ? address!.address
              : null;
        })()
            .timeout(const Duration(seconds: 5));
        if (value != null) return value;
      } on Object {
        // No addresses, response bodies or transport details in logs.
      } finally {
        client.close(force: true);
      }
    }
    return null;
  }
}
