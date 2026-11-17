import {
  CreateParticipantTokenCommand,
  CreateStageCommand,
  DeleteStageCommand,
  DisconnectParticipantCommand,
  IVSRealTimeClient,
  ParticipantTokenCapability,
} from '@aws-sdk/client-ivs-realtime';
import type { ParticipantTokenCapability as ParticipantTokenCapabilityType } from '@aws-sdk/client-ivs-realtime';
import type {
  IvsRoomEntry,
  MediaRole,
  NormalizeName,
  ProviderAdapter,
  ProviderFactoryContext,
} from '../types.ts';
import { ProviderOperationError } from './provider-registry.ts';
import { mediaCapabilityMatrix } from './provider-capabilities.ts';

export interface IvsParticipantToken {
  token: string;
  participantId: string;
  expiresAtMs?: number;
  capabilities: string[];
}

export interface IvsRealtimeApi {
  createStage(name: string): Promise<{ arn: string }>;
  createParticipantToken(input: {
    stageArn: string;
    userId: string;
    displayName: string;
    role: MediaRole;
    durationMinutes: number;
    capabilities?: ParticipantTokenCapabilityType[];
  }): Promise<IvsParticipantToken>;
  deleteStage(stageArn: string): Promise<void>;
  disconnectParticipant(
    stageArn: string,
    participantId: string,
    reason: string,
  ): Promise<void>;
}

export function normalizeIvsTokenDurationMinutes(raw: unknown): number {
  const parsed = Number(raw ?? 60);
  if (!Number.isFinite(parsed)) return 60;
  return Math.max(1, Math.min(20160, Math.trunc(parsed)));
}

function capabilitiesForRole(role: MediaRole): ParticipantTokenCapabilityType[] {
  return role === 'viewer'
    ? [ParticipantTokenCapability.SUBSCRIBE]
    : [
        ParticipantTokenCapability.PUBLISH,
        ParticipantTokenCapability.SUBSCRIBE,
      ];
}

function createAwsApi(region: string): IvsRealtimeApi {
  const client = new IVSRealTimeClient({ region });
  return {
    async createStage(name) {
      const result = await client.send(new CreateStageCommand({ name }));
      const arn = result.stage?.arn?.trim();
      if (!arn) throw new Error('IVS CreateStage returned no stage ARN.');
      return { arn };
    },
    async createParticipantToken({
      stageArn,
      userId,
      displayName,
      role,
      durationMinutes,
      capabilities,
    }) {
      const requestedCapabilities = capabilities ?? capabilitiesForRole(role);
      const result = await client.send(
        new CreateParticipantTokenCommand({
          stageArn,
          userId,
          duration: durationMinutes,
          capabilities: requestedCapabilities,
          attributes: {
            displayName,
            role,
            // Used by IVS featured-grid composition; this is a pinned host,
            // not an audio-active-speaker detector.
            isFeatured:
              role === 'host' && !userId.endsWith('#content') ? 'true' : 'false',
          },
        }),
      );
      const issued = result.participantToken;
      const token = issued?.token?.trim();
      const participantId = issued?.participantId?.trim();
      if (!token || !participantId) {
        throw new Error(
          'IVS CreateParticipantToken returned incomplete credentials.',
        );
      }
      return {
        token,
        participantId,
        capabilities: issued?.capabilities ?? requestedCapabilities,
        expiresAtMs: issued?.expirationTime?.getTime(),
      };
    },
    async deleteStage(stageArn) {
      await client.send(new DeleteStageCommand({ arn: stageArn }));
    },
    async disconnectParticipant(stageArn, participantId, reason) {
      await client.send(
        new DisconnectParticipantCommand({
          stageArn,
          participantId,
          reason: reason.slice(0, 256),
        }),
      );
    },
  };
}

function providerFailure(operation: string, error: unknown): never {
  if (error instanceof ProviderOperationError) throw error;
  const details =
    error instanceof Error
      ? { name: error.name, message: error.message }
      : String(error);
  throw new ProviderOperationError(
    502,
    'provider-api-error',
    `Amazon IVS Real-Time ${operation} failed.`,
    details,
  );
}

export function createIvsProvider({
  env = process.env,
  contractVersion,
  normalizeDisplayName,
  api: injectedApi,
}: ProviderFactoryContext & {
  normalizeDisplayName: NormalizeName;
  api?: IvsRealtimeApi;
}): ProviderAdapter {
  const region =
    env.IVS_REALTIME_REGION?.trim() ||
    env.AWS_REGION?.trim() ||
    env.AWS_DEFAULT_REGION?.trim() ||
    null;
  const tokenDurationMinutes = normalizeIvsTokenDurationMinutes(
    env.IVS_REALTIME_TOKEN_TTL_MINUTES,
  );
  const api = injectedApi ?? (region ? createAwsApi(region) : null);

  async function issueToken(
    room: IvsRoomEntry,
    userId: string,
    displayName: string,
    role: MediaRole,
    capabilities?: ParticipantTokenCapabilityType[],
  ): Promise<IvsParticipantToken> {
    if (!api) {
      throw new ProviderOperationError(
        503,
        'provider-not-configured',
        'Amazon IVS Real-Time is not configured.',
      );
    }
    try {
      return await api.createParticipantToken({
        stageArn: room.stageArn,
        userId,
        displayName,
        role,
        durationMinutes: tokenDurationMinutes,
        capabilities,
      });
    } catch (error) {
      providerFailure('CreateParticipantToken', error);
    }
  }

  return {
    id: 'ivs',
    displayName: 'Amazon IVS Real-Time',
    label: 'Amazon IVS Real-Time',
    description: 'AWS WebRTC real-time stage',
    themeKey: 'ivs',
    capabilityMatrix: mediaCapabilityMatrix({
      meeting: 'supported',
      broadcastHost: 'supported',
      broadcastViewer: 'supported',
      microphone: {
        support: 'conditional',
        note: 'participant / host 可发布，viewer token 仅 SUBSCRIBE。',
      },
      camera: {
        support: 'conditional',
        note: 'participant / host 可发布，viewer token 仅 SUBSCRIBE。',
      },
      screenShare: {
        support: 'conditional',
        note: '支持 Android / iOS / Web / macOS / Windows；单 Token 替换摄像头，配辅助 #content Token 时可双流并发。',
      },
      rtcDataSend: 'unsupported',
      rtcDataReceive: 'unsupported',
      web: {
        support: 'conditional',
        note: '通过 Amazon IVS Web Broadcast SDK Bridge 接入。',
      },
      credentialRefresh: 'supported',
      moderation: {
        support: 'supported',
        note: 'host 可通过 IVS DisconnectParticipant 移除成员。',
      },
      closeRoom: {
        support: 'supported',
        note: 'host 可关闭 Stage / 房间。',
      },
    }),
    configurationError:
      'Amazon IVS Real-Time is not configured. Set IVS_REALTIME_REGION (or AWS_REGION) and provide AWS credentials through the server IAM credential chain.',
    isConfigured: () => api != null,
    metadata: () => ({
      region,
      tokenDurationMinutes,
      platformMinimums: { android: 28, ios: '14.0' },
    }),
    supportsRole: () => true,
    async createRoom({ roomCode, role }) {
      if (!api) {
        throw new ProviderOperationError(
          503,
          'provider-not-configured',
          'Amazon IVS Real-Time is not configured.',
        );
      }
      try {
        const stage = await api.createStage(`media-${roomCode}`);
        const entry: IvsRoomEntry = {
          provider: 'ivs',
          roomCode,
          stageArn: stage.arn,
          providerRoomName: stage.arn,
          createdAt: new Date().toISOString(),
          attendees: [],
          lastHeartbeatMs: Date.now(),
        };
        return {
          entry,
          response: {
            contractVersion,
            provider: 'ivs',
            role,
            roomCode,
          },
        };
      } catch (error) {
        providerFailure('CreateStage', error);
      }
    },
    async joinRoom({ entry, rawName, role, userId }) {
      const room = entry as IvsRoomEntry;
      const displayName = normalizeDisplayName(rawName);
      const logicalUserId = String(userId ?? displayName).trim();
      if (!logicalUserId) {
        throw new ProviderOperationError(
          400,
          'invalid-argument',
          'A stable userId is required for Amazon IVS Real-Time.',
        );
      }
      const issued = await issueToken(
        room,
        logicalUserId,
        displayName || logicalUserId,
        role,
      );
      room.attendees.push({
        attendeeId: logicalUserId,
        providerParticipantId: issued.participantId,
        externalUserId: displayName || logicalUserId,
        userId: logicalUserId,
        displayName: displayName || logicalUserId,
        role,
        joinedAt: new Date().toISOString(),
      });
      room.lastHeartbeatMs = Date.now();
      return {
        contractVersion,
        provider: 'ivs',
        role,
        roomCode: room.roomCode,
        participantId: logicalUserId,
        displayName: displayName || logicalUserId,
        ivs: {
          stageArn: room.stageArn,
          token: issued.token,
          tokenParticipantId: issued.participantId,
          capabilities: issued.capabilities,
          expiresAtMs: issued.expiresAtMs,
          region,
          auxiliaryScreenToken: true,
        },
      };
    },
    async refreshCredentials({ entry, participantId }) {
      const room = entry as IvsRoomEntry;
      const attendee = room.attendees.find(
        (item) => item.attendeeId === participantId,
      );
      if (!attendee) {
        throw new ProviderOperationError(
          404,
          'participant-not-found',
          'The IVS participant is no longer registered in this room.',
        );
      }
      const role = attendee.role ?? 'participant';
      const issued = await issueToken(
        room,
        attendee.userId ?? participantId,
        attendee.displayName ?? attendee.externalUserId,
        role,
      );
      attendee.providerParticipantId = issued.participantId;
      return {
        contractVersion,
        provider: 'ivs',
        role,
        roomCode: room.roomCode,
        participantId,
        displayName: attendee.displayName ?? attendee.externalUserId,
        ivs: {
          stageArn: room.stageArn,
          token: issued.token,
          tokenParticipantId: issued.participantId,
          capabilities: issued.capabilities,
          expiresAtMs: issued.expiresAtMs,
          region,
          auxiliaryScreenToken: true,
        },
      };
    },
    async issueAuxiliaryMediaToken({ entry, participantId, action }) {
      const room = entry as IvsRoomEntry;
      const attendee = room.attendees.find(
        (item) => item.attendeeId === participantId,
      );
      if (!attendee) {
        throw new ProviderOperationError(
          404,
          'participant-not-found',
          'The IVS participant is no longer registered in this room.',
        );
      }
      if (attendee.role === 'viewer') {
        throw new ProviderOperationError(
          403,
          'forbidden',
          'Viewers cannot acquire a screen-share publishing token.',
        );
      }
      if (!api) {
        throw new ProviderOperationError(
          503,
          'provider-not-configured',
          'Amazon IVS Real-Time is not configured.',
        );
      }
      if (action === 'revoke') {
        const previousId = attendee.auxiliaryParticipantId;
        attendee.auxiliaryParticipantId = undefined;
        if (previousId) {
          try {
            await api.disconnectParticipant(
              room.stageArn,
              previousId,
              'Screen share ended',
            );
          } catch {
            // An already-disconnected auxiliary Stage stream is idempotent.
          }
        }
        return { contractVersion, provider: 'ivs', revoked: true };
      }
      const baseUserId = attendee.userId ?? participantId;
      const baseName = attendee.displayName ?? attendee.externalUserId;
      const issued = await issueToken(
        room,
        `${baseUserId}#content`,
        `${baseName}#content`,
        'participant',
        [ParticipantTokenCapability.PUBLISH],
      );
      attendee.auxiliaryParticipantId = issued.participantId;
      return {
        contractVersion,
        provider: 'ivs',
        roomCode: room.roomCode,
        participantId: `${participantId}#content`,
        ivs: {
          stageArn: room.stageArn,
          token: issued.token,
          tokenParticipantId: issued.participantId,
          capabilities: issued.capabilities,
          expiresAtMs: issued.expiresAtMs,
          region,
        },
      };
    },
    async moderateRemoveParticipant(entry, participantId) {
      const room = entry as IvsRoomEntry;
      const attendee = room.attendees.find(
        (item) => item.attendeeId === participantId,
      );
      if (!attendee) return false;
      if (!api) {
        throw new ProviderOperationError(
          503,
          'provider-not-configured',
          'Amazon IVS Real-Time is not configured.',
        );
      }
      if (attendee.providerParticipantId) {
        try {
          await api.disconnectParticipant(
            room.stageArn,
            attendee.providerParticipantId,
            'Removed by room host',
          );
        } catch (error) {
          providerFailure('DisconnectParticipant', error);
        }
      }
      room.attendees = room.attendees.filter(
        (item) => item.attendeeId !== participantId,
      );
      return true;
    },
    removeAttendee(entry, who) {
      const before = entry.attendees.length;
      entry.attendees = entry.attendees.filter(
        (attendee) => attendee.attendeeId !== String(who),
      );
      return {
        removed: entry.attendees.length !== before,
        closeWhenEmpty: false,
      };
    },
    async closeRoom({ entry }) {
      if (!api) return;
      try {
        await api.deleteStage((entry as IvsRoomEntry).stageArn);
      } catch (error) {
        providerFailure('DeleteStage', error);
      }
    },
    summarizeRoom(entry, { host }) {
      const room = entry as IvsRoomEntry;
      return {
        provider: 'ivs',
        ...(room.chatProvider ? { chatProvider: room.chatProvider } : {}),
        roomCode: room.roomCode,
        meetingId: room.stageArn,
        externalMeetingId: room.stageArn,
        mediaRegion: region ?? 'Amazon IVS',
        createdAt: room.createdAt,
        lastHeartbeat: new Date(
          room.lastHeartbeatMs ?? Date.now(),
        ).toISOString(),
        idleSec: Math.max(
          0,
          Math.round(
            (Date.now() - (room.lastHeartbeatMs ?? Date.now())) / 1000,
          ),
        ),
        attendeeCount: room.attendees.length,
        attendees: room.attendees,
        shareText: room.roomCode,
        shareLink: `multimedia://join?roomCode=${room.roomCode}&server=${host}`,
      };
    },
  };
}
