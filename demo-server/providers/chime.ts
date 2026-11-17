import crypto from 'node:crypto';
import {
  ChimeSDKMeetingsClient,
  CreateMeetingCommand,
  CreateAttendeeCommand,
  GetMeetingCommand,
  DeleteMeetingCommand,
} from '@aws-sdk/client-chime-sdk-meetings';
import type {
  ChimeAttendee,
  ChimeMeeting,
  ProviderAdapter,
  ChimeRoomEntry,
  CreateRoomResult,
  MediaRole,
  NormalizeName,
  ProviderFactoryContext,
  ProviderJoinResponse,
  RoomEntry,
} from '../types.ts';
import { mediaCapabilityMatrix } from './provider-capabilities.ts';

type RawMeeting = {
  MeetingId?: string;
  ExternalMeetingId?: string;
  MediaRegion?: string;
  MediaPlacement?: unknown;
  MeetingArn?: string;
  TenantIds?: string[];
};

type RawAttendee = {
  AttendeeId?: string;
  ExternalUserId?: string;
  JoinToken?: string;
  Capabilities?: unknown;
};

function requiredString(value: string | undefined, field: string): string {
  if (!value) throw new Error(`AWS Chime response is missing ${field}.`);
  return value;
}

function pickMeeting(raw: RawMeeting | undefined): ChimeMeeting {
  if (!raw) throw new Error('AWS Chime response is missing Meeting.');
  return {
    MeetingId: requiredString(raw.MeetingId, 'MeetingId'),
    ExternalMeetingId: raw.ExternalMeetingId,
    MediaRegion: raw.MediaRegion,
    MediaPlacement: raw.MediaPlacement, MeetingArn: raw.MeetingArn, TenantIds: raw.TenantIds ?? [],
  };
}

function pickAttendee(raw: RawAttendee | undefined): ChimeAttendee {
  if (!raw) throw new Error('AWS Chime response is missing Attendee.');
  return {
    AttendeeId: requiredString(raw.AttendeeId, 'AttendeeId'),
    ExternalUserId: requiredString(raw.ExternalUserId, 'ExternalUserId'),
    JoinToken: raw.JoinToken, Capabilities: raw.Capabilities,
  };
}

export function createChimeProvider({
  env = process.env,
  contractVersion,
  normalizeUserId,
  sendCommand,
}: ProviderFactoryContext & {
  normalizeUserId: NormalizeName;
  sendCommand?: (command: unknown) => Promise<unknown>;
}): ProviderAdapter {
  const controlRegion = env.AWS_REGION ?? 'us-east-1';
  const mediaRegion = env.CHIME_MEDIA_REGION ?? 'ap-southeast-1';
  const client = new ChimeSDKMeetingsClient({ region: controlRegion });
  const send = sendCommand ?? ((command: unknown) => client.send(command as never));
  const issuedExternalIds = new WeakMap<ChimeRoomEntry, Map<string, string>>();

  function allocateExternalUserId(
    entry: ChimeRoomEntry,
    rawName: unknown,
    userId?: string,
    deviceId?: string | null,
  ): string {
    let byIdentity = issuedExternalIds.get(entry);
    if (!byIdentity) {
      byIdentity = new Map<string, string>();
      issuedExternalIds.set(entry, byIdentity);
    }
    const identityKey = (deviceId && deviceId.trim()) || (userId && userId.trim()) || `anon-${crypto.randomUUID()}`;
    const existingForCaller = byIdentity.get(identityKey);
    if (existingForCaller) return existingForCaller;

    let base = normalizeUserId(rawName).trim();
    if (!base) base = `user-${crypto.randomUUID().slice(0, 8)}`;
    if (base.length < 2) base = `u-${base}`;
    base = base.slice(0, 64).trim();
    if (base.length < 2) base = `user-${crypto.randomUUID().slice(0, 8)}`;

    const used = new Set<string>([
      ...byIdentity.values(),
      ...entry.attendees.map((attendee) => attendee.externalUserId),
    ]);
    let candidate = base;
    let sequence = 2;
    while (used.has(candidate)) {
      const suffix = ` (${sequence})`;
      const prefix = base.slice(0, Math.max(2, 64 - suffix.length)).trimEnd();
      candidate = `${prefix}${suffix}`;
      sequence += 1;
    }
    byIdentity.set(identityKey, candidate);
    return candidate;
  }

  async function addAttendee(
    entry: ChimeRoomEntry,
    rawName: unknown,
    userId?: string,
    deviceId?: string | null,
  ): Promise<ChimeAttendee> {
    const safeId = allocateExternalUserId(entry, rawName, userId, deviceId);
    const created = (await send(new CreateAttendeeCommand({
      MeetingId: entry.meeting.MeetingId,
      ExternalUserId: safeId,
    }))) as { Attendee?: RawAttendee };
    const attendee = pickAttendee(created.Attendee);
    const displayName = String(rawName ?? '').trim().slice(0, 64) || attendee.ExternalUserId;
    entry.attendees.push({
      attendeeId: attendee.AttendeeId,
      externalUserId: attendee.ExternalUserId,
      displayName,
      joinedAt: new Date().toISOString(),
    });
    return attendee;
  }

  function joinResponse(
    entry: ChimeRoomEntry,
    attendee: ChimeAttendee,
    rawName: unknown,
    role: MediaRole = 'participant',
  ): ProviderJoinResponse {
    const displayName = String(rawName ?? '').trim().slice(0, 64) || attendee.ExternalUserId;
    return {
      contractVersion, provider: 'chime', role, roomCode: entry.roomCode,
      participantId: attendee.AttendeeId, displayName,
      meeting: entry.meeting, attendee,
    };
  }

  async function createRoom({
    roomCode,
    role,
    externalMeetingId = null,
  }: {
    roomCode: string;
    role: MediaRole;
    externalMeetingId?: string | null;
  }): Promise<CreateRoomResult> {
    const out = (await send(new CreateMeetingCommand({
      ClientRequestToken: crypto.randomUUID(),
      MediaRegion: mediaRegion,
      ExternalMeetingId: externalMeetingId ?? `room-${roomCode}`,
    }))) as { Meeting?: RawMeeting };
    const meeting = pickMeeting(out.Meeting);
    const entry: ChimeRoomEntry = {
      provider: 'chime',
      meeting,
      roomCode,
      createdAt: new Date().toISOString(),
      attendees: [],
      lastHeartbeatMs: Date.now(),
    };
    return {
      entry,
      response: { contractVersion, provider: 'chime', role, roomCode, meeting },
    };
  }

  const adapter: ProviderAdapter = {
    id: 'chime',
    displayName: 'AWS Chime',
    label: 'AWS Chime SDK',
    description: 'Amazon Chime 媒体面',
    themeKey: 'chime',
    capabilityMatrix: mediaCapabilityMatrix({
      meeting: 'supported',
      broadcastHost: {
        support: 'unsupported',
        note: '当前后端仅开放 participant 会议房间。',
      },
      broadcastViewer: {
        support: 'unsupported',
        note: '当前后端仅开放 participant 会议房间。',
      },
      microphone: 'supported',
      camera: 'supported',
      screenShare: {
        support: 'conditional',
        note: 'Web Bridge 支持内容共享；当前原生 Flutter Chime adapter 未暴露该能力。',
      },
      rtcDataSend: 'supported',
      rtcDataReceive: 'supported',
      web: {
        support: 'conditional',
        note: 'Web Bridge 支持，但角色仍仅限 participant。',
      },
      credentialRefresh: 'unsupported',
      moderation: 'unsupported',
      closeRoom: {
        support: 'unsupported',
        note: '当前没有 host 角色控制面。',
      },
    }),
    isConfigured: () => true,
    metadata: () => ({ controlRegion, mediaRegion }),
    supportsRole: (role: MediaRole) => role === 'participant',
    roleError: () => 'AWS Chime currently supports participant rooms only.',
    aliases(entry) {
      return entry.meeting?.MeetingId ? [entry.meeting.MeetingId] : [];
    },
    createRoom,
    async joinRoom({ entry, rawName, role, userId, deviceId }) {
      const room = entry as ChimeRoomEntry;
      const attendee = await addAttendee(room, rawName, userId, deviceId);
      room.lastHeartbeatMs = Date.now();
      return joinResponse(room, attendee, rawName, role);
    },
    async closeRoom({ entry }) {
      const room = entry as ChimeRoomEntry;
      try {
        await send(new DeleteMeetingCommand({ MeetingId: room.meeting.MeetingId }));
      } catch (error) {
        if (!(error instanceof Error) || error.name !== 'NotFoundException') throw error;
      }
    },
    removeAttendee(entry, who) {
      const before = entry.attendees.length;
      entry.attendees = entry.attendees.filter(
        (attendee) =>
          attendee.attendeeId !== String(who) &&
          attendee.externalUserId !== String(who),
      );
      return {
        removed: entry.attendees.length !== before,
        closeWhenEmpty: false,
      };
    },
    summarizeRoom(entry, { host }) {
      const room = entry as ChimeRoomEntry;
      return {
        provider: 'chime', roomCode: room.roomCode, meetingId: room.meeting.MeetingId,
        externalMeetingId: room.meeting.ExternalMeetingId, mediaRegion: room.meeting.MediaRegion,
        createdAt: room.createdAt,
        lastHeartbeat: new Date(room.lastHeartbeatMs ?? Date.now()).toISOString(),
        idleSec: Math.max(0, Math.round((Date.now() - (room.lastHeartbeatMs ?? Date.now())) / 1000)),
        attendeeCount: room.attendees.length, attendees: room.attendees, shareText: room.roomCode,
        shareLink: `chimedemo://join?meetingId=${room.roomCode}&server=${host}`,
      };
    },
    async resolveExternalRoom(ref, { allocateRoomCode }): Promise<RoomEntry | null> {
      try {
        const got = await client.send(new GetMeetingCommand({ MeetingId: ref }));
        const entry: ChimeRoomEntry = {
          provider: 'chime', meeting: pickMeeting(got.Meeting), roomCode: allocateRoomCode(),
          createdAt: new Date().toISOString(), attendees: [], lastHeartbeatMs: Date.now(),
        };
        return entry;
      } catch {
        return null;
      }
    },
  };

  return adapter;
}
