import assert from 'node:assert/strict';
import test from 'node:test';

import { createChimeProvider } from '../providers/chime.ts';
import { createLiveKitProvider } from '../providers/livekit.ts';
import type { ChimeRoomEntry } from '../types.ts';

const normalizeName = (raw: unknown) => String(raw ?? '').trim();

test('LiveKit removes a participant from demo room state on leave', async () => {
  const provider = createLiveKitProvider({
    env: {
      LIVEKIT_URL: 'ws://localhost:7880',
      LIVEKIT_API_KEY: 'devkey',
      LIVEKIT_API_SECRET: 'secret',
    },
    contractVersion: 1,
    normalizeDisplayName: normalizeName,
  });
  const created = await provider.createRoom({
    roomCode: 'livekit01',
    role: 'participant',
  });
  const joined = await provider.joinRoom({
    entry: created.entry,
    rawName: 'First name',
    role: 'participant',
  });

  assert.equal(created.entry.attendees.length, 1);
  const result = provider.removeAttendee?.(
    created.entry,
    joined.participantId,
  );

  assert.equal(result?.removed, true);
  assert.equal(created.entry.attendees.length, 0);
});

test('LiveKit close treats a verified missing room as successfully closed', async () => {
  const provider = createLiveKitProvider({
    env: {
      LIVEKIT_URL: 'wss://example.livekit.cloud',
      LIVEKIT_API_KEY: 'test-key',
      LIVEKIT_API_SECRET: 'test-secret',
    },
    contractVersion: 1,
    normalizeDisplayName: normalizeName,
  });
  const { entry } = await provider.createRoom({
    roomCode: 'alreadygone', role: 'participant',
  });
  const previousFetch = globalThis.fetch;
  try {
    globalThis.fetch = async (_input, init) => {
      assert.equal(JSON.parse(String(init?.body)).room, 'media-alreadygone');
      return new Response(JSON.stringify({ code: 'not_found', msg: 'room does not exist' }), {
        status: 404,
      });
    };
    await provider.closeRoom({ entry, reason: 'idle' });

    // A 404 for an invalid API route or a different error is not a
    // confirmation that the room has already been deleted.
    globalThis.fetch = async () => new Response('404 page not found', { status: 404 });
    await assert.rejects(provider.closeRoom({ entry, reason: 'idle' }), /HTTP 404/);
    globalThis.fetch = async () => new Response('{"code":"permission_denied"}', { status: 403 });
    await assert.rejects(provider.closeRoom({ entry, reason: 'idle' }), /HTTP 403/);
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test('LiveKit Meeting students cannot publish microphone before grant', async () => {
  const provider = createLiveKitProvider({
    env: {
      LIVEKIT_URL: 'ws://localhost:7880',
      LIVEKIT_API_KEY: 'devkey',
      LIVEKIT_API_SECRET: 'secret',
    },
    contractVersion: 1,
    normalizeDisplayName: normalizeName,
  });
  const { entry } = await provider.createRoom({
    roomCode: 'lesson01', role: 'participant',
  });
  entry.roomMode = 'meeting';
  const student = await provider.joinRoom({
    entry, role: 'participant', rawName: 'Student',
    classroomMicrophoneAllowed: false,
  });
  const teacher = await provider.joinRoom({
    entry, role: 'participant', rawName: 'Teacher',
    classroomMicrophoneAllowed: true,
  });
  const payload = (response: typeof student) => {
    assert.ok(response.livekit);
    const token = (response.livekit as { token: string }).token;
    return JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  };
  assert.deepEqual(payload(student).video.canPublishSources, [
    'camera', 'screen_share', 'screen_share_audio',
  ]);
  assert.equal(payload(teacher).video.canPublishSources, undefined);
  assert.equal(payload(student).video.canPublishData, true);

  const originalFetch = globalThis.fetch;
  const requests: Array<{endpoint: string; body: Record<string, unknown>}> = [];
  globalThis.fetch = async (input, init) => {
    requests.push({
      endpoint: String(input),
      body: JSON.parse(String(init?.body)) as Record<string, unknown>,
    });
    return new Response('{}', { status: 200 });
  };
  try {
    await provider.setClassroomMicrophonePermission?.(
      entry, student.participantId, true,
    );
    await provider.setClassroomMicrophonePermission?.(
      entry, student.participantId, false,
    );
    assert.equal(requests.length, 2);
    assert.match(requests[0]!.endpoint, /UpdateParticipant$/);
    assert.deepEqual((requests[0]!.body.permission as {canPublishSources: string[]}).canPublishSources, [
      'CAMERA', 'MICROPHONE', 'SCREEN_SHARE', 'SCREEN_SHARE_AUDIO',
    ]);
    assert.deepEqual((requests[1]!.body.permission as {canPublishSources: string[]}).canPublishSources, [
      'CAMERA', 'SCREEN_SHARE', 'SCREEN_SHARE_AUDIO',
    ]);
    globalThis.fetch = async () => new Response('{"code":"not_found"}', {status:404});
    await provider.setClassroomMicrophonePermission!(entry, student.participantId, false);
    await assert.rejects(provider.setClassroomMicrophonePermission!(entry, student.participantId, true), /HTTP 404/);
    globalThis.fetch = async () => new Response('{}', { status: 403 });
    await assert.rejects(
      provider.setClassroomMicrophonePermission!(entry, student.participantId, true),
      /UpdateParticipant failed with HTTP 403/,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('Chime removes locally tracked attendee state on leave', () => {
  const provider = createChimeProvider({
    env: {
      AWS_REGION: 'us-east-1',
      CHIME_MEDIA_REGION: 'us-east-1',
    },
    contractVersion: 1,
    normalizeUserId: normalizeName,
  });
  const entry: ChimeRoomEntry = {
    provider: 'chime',
    roomCode: 'chime001',
    createdAt: new Date().toISOString(),
    lastHeartbeatMs: Date.now(),
    attendees: [
      {
        attendeeId: 'attendee-1',
        externalUserId: 'First name',
        joinedAt: new Date().toISOString(),
      },
    ],
    meeting: {
      MeetingId: 'meeting-1',
      TenantIds: [],
    },
  };

  const result = provider.removeAttendee?.(entry, 'attendee-1');

  assert.equal(result?.removed, true);
  assert.equal(entry.attendees.length, 0);
});

test('Chime allocates collision-free 2-64 char ExternalUserIds for duplicate, short, and CJK names', async () => {
  const sentExternalIds: string[] = [];
  let seq = 0;
  const provider = createChimeProvider({
    env: {
      AWS_REGION: 'us-east-1',
      CHIME_MEDIA_REGION: 'us-east-1',
    },
    contractVersion: 1,
    normalizeUserId: (raw: unknown) => {
      const id = String(raw ?? '').trim();
      const ascii = id.replace(/[^\x20-\x7E]/g, '').trim();
      return ascii;
    },
    sendCommand: async (command: unknown) => {
      const input = (command as { input: Record<string, string> }).input;
      if ('MediaRegion' in input) {
        return {
          Meeting: {
            MeetingId: 'meeting-multi-peer',
            ExternalMeetingId: input.ExternalMeetingId,
            MediaRegion: input.MediaRegion,
            MediaPlacement: {},
          },
        };
      }
      sentExternalIds.push(input.ExternalUserId!);
      seq += 1;
      return {
        Attendee: {
          AttendeeId: `attendee-${seq}`,
          ExternalUserId: input.ExternalUserId,
          JoinToken: `token-${seq}`,
        },
      };
    },
  });

  const { entry } = await provider.createRoom({
    roomCode: 'awsroom1',
    role: 'participant',
  });

  const host = await provider.joinRoom({
    entry,
    rawName: 'Leo',
    role: 'participant',
    userId: 'user-ios',
    deviceId: 'device-ios-001',
  });
  const macPeer = await provider.joinRoom({
    entry,
    rawName: 'Leo',
    role: 'participant',
    userId: 'user-macos',
    deviceId: 'device-macos-002',
  });
  const shortPeer = await provider.joinRoom({
    entry,
    rawName: '张 1',
    role: 'participant',
    userId: 'user-short',
    deviceId: 'device-short-003',
  });

  assert.notEqual(host.participantId, macPeer.participantId);
  assert.equal(host.displayName, 'Leo');
  assert.equal(macPeer.displayName, 'Leo');
  assert.equal(shortPeer.displayName, '张 1');
  assert.equal(new Set(sentExternalIds).size, 3);
  for (const externalId of sentExternalIds) {
    assert.ok(externalId.length >= 2 && externalId.length <= 64, `invalid ExternalUserId length: ${externalId}`);
  }
});

