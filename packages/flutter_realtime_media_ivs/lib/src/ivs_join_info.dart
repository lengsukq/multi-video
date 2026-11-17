import 'package:flutter_realtime_media_core/flutter_realtime_media_core.dart';

class IvsJoinInfo extends MediaJoinInfo {
  IvsJoinInfo({
    required super.roomCode,
    required super.participantId,
    required super.role,
    required super.displayName,
    super.avatarUrl,
    required this.stageArn,
    required this.token,
    required this.tokenParticipantId,
    required this.capabilities,
    required this.expiresAtMs,
    this.region,
    this.auxiliaryScreenToken = false,
  }) : super(
         providerId: providerIdValue,
         payload: {
           'stageArn': stageArn,
           'token': token,
           'tokenParticipantId': tokenParticipantId,
           'capabilities': capabilities,
           'expiresAtMs': expiresAtMs,
           if (region != null) 'region': region,
         },
       );

  static const String providerIdValue = 'ivs';

  final String stageArn;
  final String token;
  final String tokenParticipantId;
  final List<String> capabilities;
  final int expiresAtMs;
  final String? region;
  final bool auxiliaryScreenToken;

  bool get canPublish => capabilities.contains('PUBLISH');
  bool get canSubscribe => capabilities.contains('SUBSCRIBE');

  factory IvsJoinInfo.fromJson(Map<String, dynamic> json) {
    final provider = json['provider']?.toString().trim().toLowerCase();
    if (provider != providerIdValue) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information does not identify Amazon IVS Real-Time.',
        providerId: providerIdValue,
      );
    }
    final roomCode = MediaJoinInfo.requireStringIn(
      json,
      'roomCode',
      providerId: providerIdValue,
    );
    final participantId = MediaJoinInfo.requireStringIn(
      json,
      'participantId',
      providerId: providerIdValue,
    );
    final role = MediaRole.tryParse(json['role']);
    if (role == null) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'IVS join information is missing a valid role.',
        providerId: providerIdValue,
      );
    }
    final block = json['ivs'];
    if (block is! Map) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'Join information is missing the IVS credential block.',
        providerId: providerIdValue,
      );
    }
    final ivs = Map<String, Object?>.from(block);
    final stageArn = MediaJoinInfo.requireStringIn(
      ivs,
      'stageArn',
      providerId: providerIdValue,
    );
    final token = MediaJoinInfo.requireStringIn(
      ivs,
      'token',
      providerId: providerIdValue,
    );
    final tokenParticipantId = MediaJoinInfo.requireStringIn(
      ivs,
      'tokenParticipantId',
      providerId: providerIdValue,
    );
    final rawCapabilities = ivs['capabilities'];
    final capabilities = rawCapabilities is List
        ? rawCapabilities
              .map((item) => item.toString().trim().toUpperCase())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    if (!capabilities.contains('SUBSCRIBE')) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'IVS participant token must allow SUBSCRIBE.',
        providerId: providerIdValue,
      );
    }
    final expectsPublish = role != MediaRole.viewer;
    if (expectsPublish != capabilities.contains('PUBLISH')) {
      throw RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: expectsPublish
            ? 'IVS publisher token must allow PUBLISH.'
            : 'IVS viewer token must not allow PUBLISH.',
        providerId: providerIdValue,
      );
    }
    final expiryValue = ivs['expiresAtMs'];
    final expiresAtMs = expiryValue is num
        ? expiryValue.toInt()
        : int.tryParse(expiryValue?.toString() ?? '') ?? 0;
    if (expiresAtMs <= 0) {
      throw const RealtimeException(
        code: RealtimeErrorCode.invalidArgument,
        message: 'IVS expiresAtMs must be a positive Unix timestamp.',
        providerId: providerIdValue,
      );
    }
    return IvsJoinInfo(
      roomCode: roomCode,
      participantId: participantId,
      role: role,
      displayName: json['displayName']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString(),
      stageArn: stageArn,
      token: token,
      tokenParticipantId: tokenParticipantId,
      capabilities: capabilities,
      expiresAtMs: expiresAtMs,
      region: ivs['region']?.toString(),
      auxiliaryScreenToken:
          ivs['auxiliaryScreenToken'] == true ||
          json['auxiliaryScreenToken'] == true,
    );
  }
}
