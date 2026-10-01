import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:kenai_core/kenai_core.dart';
import 'package:win32/win32.dart';

import 'amneziawg_config_parser.dart';
import 'vless_reality_uri_parser.dart';
import 'wireguard_config_parser.dart';

const String _pipeName = r'\\.\pipe\KenaiVpnControl-v4';
const int _maximumFrameSize = 32 * 1024;

final class ProfileProvisioningException implements Exception {
  const ProfileProvisioningException(this.code);

  final String code;

  @override
  String toString() => 'ProfileProvisioningException($code)';
}

abstract interface class ProfileIpcTransport {
  Future<Uint8List> exchange(Uint8List request);
}

final class WindowsNamedPipeProfileTransport implements ProfileIpcTransport {
  const WindowsNamedPipeProfileTransport({
    this.timeout = const Duration(seconds: 25),
  });

  final Duration timeout;

  @override
  Future<Uint8List> exchange(Uint8List request) async {
    if (!Platform.isWindows) {
      throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');
    }
    if (request.length < 12 || request.length > _maximumFrameSize) {
      throw const ProfileProvisioningException('INVALID_REQUEST');
    }
    final int timeoutMilliseconds = timeout.inMilliseconds;
    try {
      // dart:io File.open uses file creation semantics that do not work with
      // this Windows named pipe. Run bounded synchronous Win32 I/O off the UI
      // isolate instead of leaving an uncancellable File.open pending.
      return await Isolate.run(
        () => _exchangeUsingWin32(request, timeoutMilliseconds),
      );
    } on ProfileProvisioningException {
      rethrow;
    } on Object {
      throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');
    }
  }
}

Uint8List _exchangeUsingWin32(Uint8List request, int timeoutMilliseconds) {
  final Stopwatch timer = Stopwatch()..start();
  final nativePath = _pipeName.toNativeUtf16();
  HANDLE? pipe;
  try {
    while (pipe == null) {
      final result = CreateFile(
        PCWSTR(nativePath),
        GENERIC_READ | GENERIC_WRITE,
        FILE_SHARE_NONE,
        null,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        null,
      );
      if (result.value.isValid) {
        pipe = result.value;
        break;
      }
      if (result.error.code != ERROR_PIPE_BUSY.code) {
        throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');
      }
      _waitForPipe(timer, timeoutMilliseconds);
    }

    final Pointer<Uint8> input = calloc<Uint8>(request.length);
    final Pointer<Uint32> written = calloc<Uint32>();
    try {
      input.asTypedList(request.length).setAll(0, request);
      var offset = 0;
      while (offset < request.length) {
        final result = WriteFile(
          pipe,
          input + offset,
          request.length - offset,
          written,
          null,
        );
        if (!result.value || written.value == 0) {
          throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');
        }
        offset += written.value;
        _checkDeadline(timer, timeoutMilliseconds);
      }
    } finally {
      calloc.free(input);
      calloc.free(written);
    }

    final Uint8List header = _readPipeBytes(
      pipe,
      12,
      timer,
      timeoutMilliseconds,
    );
    final int bodyLength =
        ByteData.sublistView(header).getUint32(8, Endian.little);
    if (bodyLength > _maximumFrameSize - 12) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
    final Uint8List body = _readPipeBytes(
      pipe,
      bodyLength,
      timer,
      timeoutMilliseconds,
    );
    return Uint8List.fromList(<int>[...header, ...body]);
  } finally {
    pipe?.close();
    calloc.free(nativePath);
  }
}

Uint8List _readPipeBytes(
  HANDLE pipe,
  int length,
  Stopwatch timer,
  int timeoutMilliseconds,
) {
  if (length == 0) return Uint8List(0);
  final Pointer<Uint8> buffer = calloc<Uint8>(length);
  final Pointer<Uint32> available = calloc<Uint32>();
  final Pointer<Uint32> bytesRead = calloc<Uint32>();
  try {
    var offset = 0;
    while (offset < length) {
      _checkDeadline(timer, timeoutMilliseconds);
      final peek = PeekNamedPipe(pipe, null, 0, null, available, null);
      if (!peek.value) {
        throw const ProfileProvisioningException('SERVICE_UNAVAILABLE');
      }
      if (available.value == 0) {
        _waitForPipe(timer, timeoutMilliseconds);
        continue;
      }
      final int count = min(length - offset, available.value);
      final read = ReadFile(pipe, buffer + offset, count, bytesRead, null);
      if (!read.value || bytesRead.value == 0) {
        throw const ProfileProvisioningException('INVALID_RESPONSE');
      }
      offset += bytesRead.value;
    }
    return Uint8List.fromList(buffer.asTypedList(length));
  } finally {
    calloc.free(buffer);
    calloc.free(available);
    calloc.free(bytesRead);
  }
}

void _waitForPipe(Stopwatch timer, int timeoutMilliseconds) {
  _checkDeadline(timer, timeoutMilliseconds);
  sleep(const Duration(milliseconds: 10));
}

void _checkDeadline(Stopwatch timer, int timeoutMilliseconds) {
  if (timer.elapsedMilliseconds >= timeoutMilliseconds) {
    throw const ProfileProvisioningException('SERVICE_TIMEOUT');
  }
}

final class WindowsVpnProfileProvisioner implements VpnProfileProvisioner {
  WindowsVpnProfileProvisioner({
    ProfileIpcTransport transport = const WindowsNamedPipeProfileTransport(),
    WireGuardConfigParser parser = const WireGuardConfigParser(),
    AmneziaWgConfigParser amneziaWgParser = const AmneziaWgConfigParser(),
    VlessRealityUriParser vlessRealityParser = const VlessRealityUriParser(),
    Random? random,
  })  : _transport = transport,
        _parser = parser,
        _amneziaWgParser = amneziaWgParser,
        _vlessRealityParser = vlessRealityParser,
        _random = random ?? Random.secure();

  final ProfileIpcTransport _transport;
  final WireGuardConfigParser _parser;
  final AmneziaWgConfigParser _amneziaWgParser;
  final VlessRealityUriParser _vlessRealityParser;
  final Random _random;

  @override
  Future<String> provisionWireGuard(String configuration) async {
    final WireGuardProvisioningProfile profile = _parser.parse(configuration);
    final String requestId = _identifier('request');
    final Uint8List response = await _transport.exchange(
      _encodeImport(requestId, _identifier('provision'), profile),
    );
    final VpnIpcResponse decoded = decodeVpnIpcResponse(response, requestId);
    if (decoded.code != 'PROFILE_STORED' || decoded.profileId == null) {
      throw ProfileProvisioningException(decoded.code);
    }
    return decoded.profileId!;
  }

  @override
  Future<String> provisionAmneziaWg(String configuration) async {
    final AmneziaWgProvisioningProfile profile = _amneziaWgParser.parse(
      configuration,
    );
    final String requestId = _identifier('request');
    final Uint8List response = await _transport.exchange(
      _encodeAmneziaWgImport(requestId, _identifier('provision'), profile),
    );
    final VpnIpcResponse decoded = decodeVpnIpcResponse(response, requestId);
    if (decoded.code != 'PROFILE_STORED' || decoded.profileId == null) {
      throw ProfileProvisioningException(decoded.code);
    }
    return decoded.profileId!;
  }

  @override
  Future<String> provisionVlessReality(String configuration) async {
    final VlessRealityProvisioningProfile profile = _vlessRealityParser.parse(
      configuration,
    );
    final String requestId = _identifier('request');
    final Uint8List response = await _transport.exchange(
      _encodeVlessImport(requestId, _identifier('provision'), profile),
    );
    final VpnIpcResponse decoded = decodeVpnIpcResponse(response, requestId);
    if (decoded.code != 'PROFILE_STORED' || decoded.profileId == null) {
      throw ProfileProvisioningException(decoded.code);
    }
    return decoded.profileId!;
  }

  @override
  Future<void> deleteProfile(String profileId) async {
    if (!_validIdentifier(profileId)) {
      throw const ProfileProvisioningException('INVALID_PROFILE_HANDLE');
    }
    final String requestId = _identifier('request');
    final Uint8List response = await _transport.exchange(
      _encodeDelete(requestId, _identifier('cleanup'), profileId),
    );
    final VpnIpcResponse decoded = decodeVpnIpcResponse(response, requestId);
    if (decoded.code != 'PROFILE_DELETED' &&
        decoded.code != 'PROFILE_NOT_FOUND') {
      throw ProfileProvisioningException(decoded.code);
    }
  }

  String _identifier(String prefix) {
    final StringBuffer value = StringBuffer('$prefix-');
    for (var index = 0; index < 16; index += 1) {
      value.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return value.toString();
  }
}

Uint8List _encodeImport(
  String requestId,
  String operationId,
  WireGuardProvisioningProfile profile,
) {
  final BytesBuilder body = BytesBuilder(copy: false)
    ..add(_identifierBytes(requestId))
    ..add(_identifierBytes(operationId))
    ..add(profile.privateKey)
    ..add(_stringList(profile.addresses))
    ..add(_stringList(profile.dnsServers))
    ..add(profile.peerPublicKey);
  if (profile.presharedKey == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(profile.presharedKey!);
  }
  body
    ..add(_boundedString(profile.endpointHost))
    ..add(_u16(profile.endpointPort))
    ..add(_stringList(profile.allowedIps));
  if (profile.persistentKeepalive == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(_u16(profile.persistentKeepalive!));
  }
  return encodeVpnIpcFrame(5, body.takeBytes());
}

Uint8List _encodeDelete(
  String requestId,
  String operationId,
  String profileId,
) =>
    encodeVpnIpcFrame(
      6,
      Uint8List.fromList(<int>[
        ..._identifierBytes(requestId),
        ..._identifierBytes(operationId),
        ..._identifierBytes(profileId),
      ]),
    );

Uint8List _encodeAmneziaWgImport(
  String requestId,
  String operationId,
  AmneziaWgProvisioningProfile profile,
) {
  final WireGuardProvisioningProfile wg = profile.wireGuard;
  final BytesBuilder body = BytesBuilder(copy: false)
    ..add(_identifierBytes(requestId))
    ..add(_identifierBytes(operationId))
    ..add(wg.privateKey)
    ..add(_stringList(wg.addresses))
    ..add(_stringList(wg.dnsServers))
    ..add(wg.peerPublicKey);
  if (wg.presharedKey == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(wg.presharedKey!);
  }
  body
    ..add(_boundedString(wg.endpointHost))
    ..add(_u16(wg.endpointPort))
    ..add(_stringList(wg.allowedIps));
  if (wg.persistentKeepalive == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(_u16(wg.persistentKeepalive!));
  }
  for (final int value in <int>[
    profile.jc,
    profile.jmin,
    profile.jmax,
    profile.s1,
    profile.s2,
    profile.s3,
    profile.s4,
  ]) {
    body.add(_u16(value));
  }
  for (final String value in <String>[
    profile.h1,
    profile.h2,
    profile.h3,
    profile.h4,
  ]) {
    body.add(_boundedString(value));
  }
  body.addByte(profile.specialJunk.length);
  for (final String value in profile.specialJunk) {
    body.add(_longString(value));
  }
  if (profile.headerProtectionKey == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(profile.headerProtectionKey!);
  }
  for (final String? value in <String?>[
    profile.contentPaddingAddition,
    profile.rekeyAfterTime,
    profile.rekeyTimeout,
    profile.rejectAfterTime,
    profile.keepaliveTimeout,
    profile.maxHandshakeAttempts,
  ]) {
    if (value == null) {
      body.addByte(0);
    } else {
      body
        ..addByte(1)
        ..add(_boundedString(value));
    }
  }
  for (final bool? value in <bool?>[
    profile.randomTrailers,
    profile.disableCookies,
  ]) {
    body.addByte(value == null ? 0 : (value ? 2 : 1));
  }
  if (profile.mtu == null) {
    body.addByte(0);
  } else {
    body
      ..addByte(1)
      ..add(_u16(profile.mtu!));
  }
  return encodeVpnIpcFrame(8, body.takeBytes());
}

Uint8List _longString(String value) {
  final Uint8List encoded = Uint8List.fromList(utf8.encode(value));
  if (encoded.isEmpty ||
      encoded.length > 4096 ||
      value.runes.any((int rune) => rune < 32 || rune == 127)) {
    throw const ProfileProvisioningException('INVALID_PROFILE');
  }
  return Uint8List.fromList(<int>[..._u16(encoded.length), ...encoded]);
}

Uint8List _encodeVlessImport(
  String requestId,
  String operationId,
  VlessRealityProvisioningProfile profile,
) {
  final BytesBuilder body = BytesBuilder(copy: false)
    ..add(_identifierBytes(requestId))
    ..add(_identifierBytes(operationId))
    ..add(_boundedString(profile.clientId))
    ..add(_boundedString(profile.endpointHost))
    ..add(_u16(profile.endpointPort))
    ..add(_boundedString(profile.serverName))
    ..add(_boundedString(profile.fingerprint))
    ..add(_boundedString(profile.realityPassword))
    ..add(_optionalBoundedString(profile.shortId))
    ..add(_longString(profile.spiderX));
  return encodeVpnIpcFrame(9, body.takeBytes());
}

Uint8List _optionalBoundedString(String value) {
  final Uint8List encoded = Uint8List.fromList(utf8.encode(value));
  if (encoded.length > 253 || encoded.contains(0)) {
    throw const ProfileProvisioningException('INVALID_PROFILE');
  }
  return Uint8List.fromList(<int>[encoded.length, ...encoded]);
}

Uint8List encodeVpnIpcFrame(int opcode, Uint8List body) {
  if (body.length + 12 > _maximumFrameSize) {
    throw const ProfileProvisioningException('PROFILE_TOO_LARGE');
  }
  final Uint8List frame = Uint8List(body.length + 12);
  frame.setRange(0, 4, const <int>[0x4b, 0x56, 0x50, 0x4e]);
  ByteData.sublistView(frame)
    ..setUint16(4, 5, Endian.little)
    ..setUint8(6, opcode)
    ..setUint8(7, 0)
    ..setUint32(8, body.length, Endian.little);
  frame.setRange(12, frame.length, body);
  return frame;
}

Uint8List _identifierBytes(String value) {
  if (!_validIdentifier(value)) {
    throw const ProfileProvisioningException('INVALID_IDENTIFIER');
  }
  return _boundedString(value);
}

bool _validIdentifier(String value) =>
    value.isNotEmpty &&
    value.length <= 64 &&
    RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);

Uint8List _boundedString(String value) {
  final Uint8List encoded = Uint8List.fromList(value.codeUnits);
  if (encoded.isEmpty || encoded.length > 253 || encoded.contains(0)) {
    throw const ProfileProvisioningException('INVALID_PROFILE');
  }
  return Uint8List.fromList(<int>[encoded.length, ...encoded]);
}

Uint8List _stringList(List<String> values) => Uint8List.fromList(<int>[
      values.length,
      for (final String value in values) ..._boundedString(value),
    ]);

Uint8List _u16(int value) {
  final Uint8List bytes = Uint8List(2);
  ByteData.sublistView(bytes).setUint16(0, value, Endian.little);
  return bytes;
}

VpnIpcResponse decodeVpnIpcResponse(Uint8List frame, String expectedRequestId) {
  if (frame.length < 12 || frame.length > _maximumFrameSize) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  final ByteData data = ByteData.sublistView(frame);
  if (frame[0] != 0x4b ||
      frame[1] != 0x56 ||
      frame[2] != 0x50 ||
      frame[3] != 0x4e ||
      data.getUint16(4, Endian.little) != 5 ||
      frame[6] != 0x81 ||
      frame[7] != 0 ||
      data.getUint32(8, Endian.little) != frame.length - 12) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  final _Cursor cursor = _Cursor(frame, 12);
  final String requestId = cursor.string();
  final int phase = cursor.byte();
  if (phase > 9) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  final int hasProfile = cursor.byte();
  final String? profileId = switch (hasProfile) {
    0 => null,
    1 => cursor.string(),
    _ => throw const ProfileProvisioningException('INVALID_RESPONSE'),
  };
  final int killSwitch = cursor.byte();
  if (killSwitch != 0 && killSwitch != 1) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  final String code = cursor.string();
  final int hasStatistics = cursor.byte();
  int? bytesReceived;
  int? bytesSent;
  int? lastHandshakeUnixMs;
  if (hasStatistics == 1) {
    bytesReceived = cursor.uint64();
    bytesSent = cursor.uint64();
    final int hasHandshake = cursor.byte();
    if (hasHandshake == 1) {
      lastHandshakeUnixMs = cursor.int64();
    } else if (hasHandshake != 0) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
  } else if (hasStatistics != 0) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  if (!cursor.finished ||
      requestId != expectedRequestId ||
      !_validIdentifier(code) ||
      (profileId != null && !_validIdentifier(profileId))) {
    throw const ProfileProvisioningException('INVALID_RESPONSE');
  }
  return VpnIpcResponse(
    phase: phase,
    profileId: profileId,
    killSwitchActive: killSwitch == 1,
    code: code,
    bytesReceived: bytesReceived,
    bytesSent: bytesSent,
    lastHandshakeUnixMs: lastHandshakeUnixMs,
  );
}

final class VpnIpcResponse {
  const VpnIpcResponse({
    required this.phase,
    required this.profileId,
    required this.killSwitchActive,
    required this.code,
    required this.bytesReceived,
    required this.bytesSent,
    required this.lastHandshakeUnixMs,
  });

  final int phase;
  final String? profileId;
  final bool killSwitchActive;
  final String code;
  final int? bytesReceived;
  final int? bytesSent;
  final int? lastHandshakeUnixMs;
}

final class _Cursor {
  _Cursor(this.bytes, this.offset);

  final Uint8List bytes;
  int offset;

  bool get finished => offset == bytes.length;

  int byte() {
    if (offset >= bytes.length) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
    return bytes[offset++];
  }

  String string() {
    final int length = byte();
    final int end = offset + length;
    if (end > bytes.length) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
    final String value = String.fromCharCodes(bytes.sublist(offset, end));
    offset = end;
    return value;
  }

  int uint64() {
    if (offset + 8 > bytes.length) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
    final int value =
        ByteData.sublistView(bytes).getUint64(offset, Endian.little);
    offset += 8;
    return value;
  }

  int int64() {
    if (offset + 8 > bytes.length) {
      throw const ProfileProvisioningException('INVALID_RESPONSE');
    }
    final int value =
        ByteData.sublistView(bytes).getInt64(offset, Endian.little);
    offset += 8;
    return value;
  }
}
