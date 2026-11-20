import assert from 'node:assert/strict';
import type { classroomToolsSnapshot } from '../classroom/classroom-tools.ts';
import { spawn, type ChildProcess } from 'node:child_process';
import { once } from 'node:events';
import { writeFileSync } from 'node:fs';
import { createServer, type Server } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import test, { after, before } from 'node:test';

let serverProcess: ChildProcess | undefined;
let liveKitServer: Server | undefined;
let baseUrl: string | undefined;
let output = '';
const liveKitRoomServiceCalls: string[] = [];
let failLiveKitDeleteRoom = false;
let failLiveKitUpdateParticipant = false;
const liveKitUpdates: Array<{identity: string; permission: {canPublishSources: string[]}}> = [];
let updateGate: { entered: () => void; wait: Promise<void> } | null = null;
function holdNextUpdate() {
  let enter!: () => void, release!: () => void;
  const entered = new Promise<void>(resolve => { enter = resolve; });
  const wait = new Promise<void>(resolve => { release = resolve; });
  updateGate = { entered: enter, wait };
  return { entered, release };
}

interface ApiBody {
  liveInteractions?: boolean;
  totalLikes?: number;
  likeEvents?: Array<{ id: string; userId: string; sequence: number }>;
  tools?: Record<string, unknown>;
  totals?: Record<string, number>;
  activeProvider?: string;
  activeChatProvider?: string | null;
  provider?: string;
  engine?: string;
  roomCode?: string;
  participantId?: string;
  participantCredential?: string;
  roomOwnerCredential?: string;
  role?: string;
  roomMode?: string;
  meetingMode?: string;
  meeting?: { MeetingId?: string };
  attendee?: { AttendeeId?: string };
  speakEnforcement?: string;
  livekit?: { token: string };
  revision?: number;
  selfUserId?: string;
  stats?: { onlineCount: number; handsRaised: number; pendingQuestions: number };
  students?: Array<{ userId: string; handRaised: boolean; canSpeak: boolean; online?: boolean }>;
  questions?: Array<{ id: string; text: string; status: string; answer?: string }>;
  feedbackSupported?: boolean;
  feedback?: Array<{ id: string; userId: string; displayName: string; kind: string; createdAt: string }>;
  providerList?: Array<{
    id: string;
    capabilities?: Array<{
      key?: string;
      support?: string;
      note?: string;
    }>;
  }>;
  providers?: Record<
    string,
    {
      configured?: boolean;
      engines?: Record<string, string>;
      capabilities?: Array<{ key?: string; support?: string }>;
    }
  >;
  participants?: Array<{
    participantId?: string;
    displayName?: string;
    role?: string;
    joinedAt?: string;
    deviceId?: string;
    userId?: string;
  }>;
  rooms?: Array<{
    provider?: string;
    roomCode?: string;
    roomMode?: string;
  meetingMode?: string;
    attendeeCount?: number;
    attendees?: Array<{
      externalUserId?: string;
      deviceId?: string;
      role?: string;
    }>;
  }>;
  error?: { code?: string };
}

function requireBaseUrl(): string {
  assert.ok(baseUrl, 'test server URL is not available');
  return baseUrl;
}

before(async () => {
  liveKitServer = createServer((req, res) => {
    if (req.url?.startsWith('/twirp/livekit.RoomService/')) {
      liveKitRoomServiceCalls.push(req.url);
      if (req.url === '/twirp/livekit.RoomService/UpdateParticipant') {
        let body = '';
        req.setEncoding('utf8');
        req.on('data', chunk => { body += chunk; });
        req.on('end', async () => {
          liveKitUpdates.push(JSON.parse(body));
          const gate = updateGate;
          updateGate = null;
          if (gate) { gate.entered(); await gate.wait; }
          res.writeHead(failLiveKitUpdateParticipant ? 500 : 200, { 'Content-Type': 'application/json' });
          res.end('{}');
        });
        return;
      }
      req.resume();
      if (
        failLiveKitDeleteRoom &&
        req.url === '/twirp/livekit.RoomService/DeleteRoom'
      ) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end('{}');
        return;
      }
      if (failLiveKitUpdateParticipant &&
          req.url === '/twirp/livekit.RoomService/UpdateParticipant') {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end('{}');
        return;
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{}');
      return;
    }
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end('{}');
  });
  await new Promise<void>((resolve, reject) => {
    liveKitServer?.once('error', reject);
    liveKitServer?.listen(0, '127.0.0.1', resolve);
  });
  const liveKitAddress = liveKitServer.address();
  assert.ok(liveKitAddress && typeof liveKitAddress === 'object');
  const liveKitUrl = `ws://127.0.0.1:${liveKitAddress.port}`;

  const stateFile = path.join(os.tmpdir(), `provider-routing-test-${process.pid}.json`);
  writeFileSync(
    stateFile,
    JSON.stringify({ provider: 'livekit', chatProvider: 'none' }),
    'utf8',
  );
  serverProcess = spawn(process.execPath, ['server.ts'], {
    cwd: path.resolve(import.meta.dirname, '..'),
    env: {
      PATH: process.env.PATH,
      PORT: '0',
      MEDIA_DEFAULT_PROVIDER: 'livekit',
      CHAT_DEFAULT_PROVIDER: 'ivs-chat',
      IVS_CHAT_REGION: 'us-west-2',
      MEDIA_PROVIDER_STATE_PATH: stateFile,
      LIVEKIT_URL: liveKitUrl,
      LIVEKIT_API_KEY: 'test-api-key',
      LIVEKIT_API_SECRET: 'test-api-secret',
      EMPTY_CLOSE_AFTER_MS: '60000',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProcess.stdout?.setEncoding('utf8');
  serverProcess.stderr?.setEncoding('utf8');
  serverProcess.stdout?.on('data', (chunk: string) => {
    output += chunk;
    const match = output.match(/media-demo-server on :(\d+)/);
    if (match) baseUrl = `http://127.0.0.1:${match[1]}`;
  });
  serverProcess.stderr?.on('data', (chunk: string) => { output += chunk; });

  const started = Date.now();
  while (!baseUrl && Date.now() - started < 10000) {
    if (serverProcess.exitCode != null) throw new Error(`Provider routing test server exited: ${output}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  assert.ok(baseUrl, `Provider routing test server did not start: ${output}`);
});

after(async () => {
  if (serverProcess && serverProcess.exitCode == null) {
    serverProcess.kill('SIGTERM');
    await Promise.race([once(serverProcess, 'exit'), new Promise((resolve) => setTimeout(resolve, 3000))]);
  }
  if (liveKitServer?.listening) {
    await new Promise<void>((resolve, reject) => {
      liveKitServer?.close((error) => error ? reject(error) : resolve());
    });
  }
});

async function post(
  endpoint: string,
  body: Record<string, unknown>,
): Promise<{ status: number; body: ApiBody }> {
  const response = await fetch(`${requireBaseUrl()}${endpoint}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Media-Backend-Contract': '1' },
    body: JSON.stringify(body),
  });
  return { status: response.status, body: await response.json() as ApiBody };
}

test('provider metadata is dynamic and unconfigured providers cannot be selected', async () => {
  const overviewResponse = await fetch(`${requireBaseUrl()}/api/overview`);
  const overview = await overviewResponse.json() as ApiBody;

  assert.equal(overview.activeProvider, 'livekit');
  assert.equal(
    overview.activeChatProvider,
    null,
    'persisted chatProvider=none must override CHAT_DEFAULT_PROVIDER',
  );
  assert.ok(Array.isArray(overview.providerList));
  assert.equal(overview.providerList.some((provider: { id: string }) => provider.id === 'livekit'), true);
  assert.equal(overview.providers?.livekit?.configured, true);
  assert.equal(overview.providers?.agora?.configured, false);
  const livekitMetadata = overview.providerList.find(
    (provider) => provider.id === 'livekit',
  );
  assert.ok(Array.isArray(livekitMetadata?.capabilities));
  assert.equal(
    livekitMetadata?.capabilities?.some(
      (capability) =>
        capability.key === 'rtcDataSend' && capability.support === 'supported',
    ),
    true,
  );
  assert.equal(overview.providers?.chime, undefined);
  assert.equal(overview.providers?.ivs, undefined);
  assert.equal(overview.providers?.aws?.engines?.meeting, 'chime');
  assert.equal(overview.providers?.aws?.engines?.broadcast, 'ivs');

  const unconfigured = await post('/api/provider', { provider: 'agora' });
  assert.equal(unconfigured.status, 503);
  assert.ok(unconfigured.body.error);
  assert.equal(unconfigured.body.error.code, 'provider-not-configured');
});

test('switching the active provider does not change an existing room provider', async () => {
  const created = await post('/rooms', {
    roomCode: 'stickyRoom1',
    nickname: 'Host',
    roomMode: 'meeting',
    deviceId: 'device-sticky-001',
  });
  assert.equal(created.status, 200);
  assert.equal(created.body.provider, 'livekit');
  assert.equal(created.body.role, 'participant');
  assert.equal(created.body.roomMode, 'meeting');
  assert.ok(created.body.roomOwnerCredential);

  const rejoinedSameDevice = await post('/rooms/stickyRoom1/join', {
    userId: 'Renamed Host',
    deviceId: 'device-sticky-001',
    roomOwnerCredential: created.body.roomOwnerCredential,
  });
  assert.equal(rejoinedSameDevice.status, 200);
  assert.equal(rejoinedSameDevice.body.role, 'participant');
  assert.equal(
    rejoinedSameDevice.body.roomOwnerCredential,
    created.body.roomOwnerCredential,
  );

  const meetingParticipants = await post('/rooms/stickyRoom1/participants', {
    requesterParticipantId: rejoinedSameDevice.body.participantId,
    participantCredential: rejoinedSameDevice.body.participantCredential,
    roomOwnerCredential: rejoinedSameDevice.body.roomOwnerCredential,
  });
  assert.equal(meetingParticipants.status, 200);
  assert.equal(meetingParticipants.body.participants?.length, 1);
  assert.equal(meetingParticipants.body.participants?.[0]?.userId, 'Renamed Host');

  const meetingGuest = await post('/rooms/stickyRoom1/join', {
    userId: 'meeting-guest',
    displayName: 'Meeting Guest',
    deviceId: 'device-sticky-guest-001',
  });
  assert.equal(meetingGuest.status, 200);
  assert.equal(meetingGuest.body.role, 'participant');
  assert.ok(meetingGuest.body.livekit?.token);
  const guestToken = JSON.parse(
    Buffer.from(meetingGuest.body.livekit.token.split('.')[1]!, 'base64url').toString(),
  ) as {video: {canPublishSources?: string[]}};
  assert.ok(!guestToken.video.canPublishSources?.includes('microphone'));

  const studentAuth = {
    requesterParticipantId: meetingGuest.body.participantId,
    participantCredential: meetingGuest.body.participantCredential,
  };
  const teacherAuth = {
    requesterParticipantId: rejoinedSameDevice.body.participantId,
    participantCredential: rejoinedSameDevice.body.participantCredential,
    roomOwnerCredential: rejoinedSameDevice.body.roomOwnerCredential,
  };
  const initialClassroom = await post('/rooms/stickyRoom1/classroom/snapshot', studentAuth);
  assert.equal(initialClassroom.status, 200);
  assert.equal(initialClassroom.body.role, 'student');
  assert.equal(initialClassroom.body.selfUserId, 'meeting-guest');
  assert.equal(initialClassroom.body.speakEnforcement, 'provider');
  const unauthenticated = await post('/rooms/stickyRoom1/classroom/snapshot', {
    requesterParticipantId: meetingGuest.body.participantId,
  });
  assert.equal(unauthenticated.status, 403);
  const hand = await post('/rooms/stickyRoom1/classroom/action', {
    ...studentAuth, action: 'hand.raise',
  });
  assert.equal(hand.status, 200);
  assert.equal(hand.body.stats?.handsRaised, 1);
  const forgedGrant = await post('/rooms/stickyRoom1/classroom/action', {
    ...studentAuth, action: 'speak.grant', userId: 'meeting-guest',
  });
  assert.equal(forgedGrant.status, 403);
  const granted = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'speak.grant', userId: 'meeting-guest',
  });
  assert.equal(granted.status, 200);
  assert.equal(granted.body.students?.find(s => s.userId === 'meeting-guest')?.canSpeak, true);
  assert.ok(liveKitRoomServiceCalls.includes('/twirp/livekit.RoomService/UpdateParticipant'));
  const vendorUpdatesAfterGrant = liveKitRoomServiceCalls.filter(
    call => call === '/twirp/livekit.RoomService/UpdateParticipant',
  ).length;
  const unchangedGrant = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'speak.grant', userId: 'meeting-guest',
  });
  assert.equal(unchangedGrant.status, 200);
  assert.equal(liveKitRoomServiceCalls.filter(
    call => call === '/twirp/livekit.RoomService/UpdateParticipant',
  ).length, vendorUpdatesAfterGrant);
  const invalidReplayId = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'speak.revoke', userId: 'meeting-guest',
    eventId: 'invalid!',
  });
  assert.equal(invalidReplayId.status, 400);
  assert.equal(liveKitRoomServiceCalls.filter(
    call => call === '/twirp/livekit.RoomService/UpdateParticipant',
  ).length, vendorUpdatesAfterGrant);
  failLiveKitUpdateParticipant = true;
  const remoteRevokeFailure = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'speak.revoke', userId: 'meeting-guest',
  });
  failLiveKitUpdateParticipant = false;
  assert.equal(remoteRevokeFailure.status, 502);
  const unchangedPermission = await post('/rooms/stickyRoom1/classroom/snapshot', studentAuth);
  assert.equal(unchangedPermission.body.students?.find(s => s.userId === 'meeting-guest')?.canSpeak, true);
  const revoked = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'speak.revoke', userId: 'meeting-guest',
  });
  assert.equal(revoked.status, 200);
  assert.equal(revoked.body.students?.find(s => s.userId === 'meeting-guest')?.canSpeak, false);
  const asked = await post('/rooms/stickyRoom1/classroom/action', {
    ...studentAuth, action: 'question.ask', text: 'How does RTC work?',
  });
  assert.equal(asked.status, 200);
  assert.equal(asked.body.stats?.pendingQuestions, 1);
  const questionId = asked.body.questions?.[0]?.id;
  const answered = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'question.answer', questionId, text: 'Real-time media',
  });
  assert.equal(answered.status, 200);
  assert.equal(answered.body.questions?.[0]?.status, 'answered');
  const resolved = await post('/rooms/stickyRoom1/classroom/action', {
    ...teacherAuth, action: 'question.resolve', questionId,
  });
  assert.equal(resolved.status, 200);
  assert.equal(resolved.body.questions?.[0]?.status, 'resolved');
  const forgedTeacher = await post('/rooms/stickyRoom1/classroom/snapshot', {
    ...studentAuth, roomOwnerCredential: 'incorrect-owner-proof',
  });
  assert.equal(forgedTeacher.status, 403);

  const forbiddenMeetingManagement = await post(
    '/rooms/stickyRoom1/participants',
    {
      requesterParticipantId: meetingGuest.body.participantId,
      participantCredential: meetingGuest.body.participantCredential,
    },
  );
  assert.equal(forbiddenMeetingManagement.status, 403);

  const removeMeetingGuest = await post(
    '/rooms/stickyRoom1/participants/remove',
    {
      requesterParticipantId: rejoinedSameDevice.body.participantId,
      participantCredential: rejoinedSameDevice.body.participantCredential,
      roomOwnerCredential: rejoinedSameDevice.body.roomOwnerCredential,
      targetParticipantId: meetingGuest.body.participantId,
    },
  );
  assert.equal(removeMeetingGuest.status, 200);

  const rosterAfterRemoval = await post(
    '/rooms/stickyRoom1/classroom/snapshot',
    teacherAuth,
  );
  assert.equal(rosterAfterRemoval.status, 200);
  assert.equal(rosterAfterRemoval.body.stats?.onlineCount, 1);
  assert.equal(
    rosterAfterRemoval.body.students?.find((s) => s.userId === 'meeting-guest')?.online,
    false,
  );

  const invalidMeetingOwner = await post('/rooms/stickyRoom1/join', {
    userId: 'fake-owner',
    displayName: 'Fake Owner',
    roomOwnerCredential: 'invalid-owner-proof',
  });
  assert.equal(invalidMeetingOwner.status, 403);

  const participantHeartbeat = await post('/rooms/stickyRoom1/heartbeat', {
    participantId: rejoinedSameDevice.body.participantId,
  });
  assert.equal(participantHeartbeat.status, 200);

  const staleHeartbeat = await post('/rooms/stickyRoom1/heartbeat', {
    participantId: 'missing-participant',
  });
  assert.equal(staleHeartbeat.status, 404);
  assert.equal(staleHeartbeat.body.error?.code, 'participant-not-found');

  const presenceResponse = await fetch(`${requireBaseUrl()}/api/overview`);
  const presence = await presenceResponse.json() as ApiBody;
  const stickyRoom = presence.rooms?.find((room) => room.roomCode === 'stickyRoom1');
  assert.equal(stickyRoom?.attendeeCount, 1);
  assert.equal(stickyRoom?.attendees?.[0]?.externalUserId, 'Renamed Host');
  assert.equal(stickyRoom?.attendees?.[0]?.deviceId, 'device-sticky-001');

  const broadcast = await post('/rooms', {
    roomCode: 'broadcast01',
    displayName: 'Creator',
    userId: 'creator-user',
    roomMode: 'broadcast',
    deviceId: 'device-creator-001',
  });
  assert.equal(broadcast.status, 200);
  assert.equal(broadcast.body.role, 'host');
  assert.equal(broadcast.body.roomMode, 'broadcast');
  assert.ok(broadcast.body.roomOwnerCredential);

  const viewer = await post('/rooms/broadcast01/join', {
    userId: 'viewer-user',
    displayName: 'Viewer',
    deviceId: 'device-viewer-001',
  });
  assert.equal(viewer.status, 200);
  assert.equal(viewer.body.role, 'viewer');

  const spoofedCreator = await post('/rooms/broadcast01/join', {
    userId: 'creator-user',
    displayName: 'Impersonated Creator',
    deviceId: 'device-creator-001',
  });
  assert.equal(spoofedCreator.status, 200);
  assert.equal(
    spoofedCreator.body.role,
    'viewer',
    'client-declared creator userId/deviceId must never restore host',
  );

  const wrongOwnerProof = await post('/rooms/broadcast01/join', {
    userId: 'creator-user',
    displayName: 'Fake Creator',
    deviceId: 'device-creator-001',
    roomOwnerCredential: 'not-the-owner-proof',
  });
  assert.equal(wrongOwnerProof.status, 403);

  const creatorRejoin = await post('/rooms/broadcast01/join', {
    userId: 'creator-user',
    displayName: 'Creator again',
    deviceId: 'device-creator-001',
    roomOwnerCredential: broadcast.body.roomOwnerCredential,
  });
  assert.equal(creatorRejoin.status, 200);
  assert.equal(creatorRejoin.body.role, 'host');

  const forbiddenParticipants = await post('/rooms/broadcast01/participants', {
    requesterParticipantId: viewer.body.participantId,
    participantCredential: viewer.body.participantCredential,
  });
  assert.equal(forbiddenParticipants.status, 403);
  assert.equal(forbiddenParticipants.body.error?.code, 'forbidden');

  const hostParticipants = await post('/rooms/broadcast01/participants', {
    requesterParticipantId: creatorRejoin.body.participantId,
    participantCredential: creatorRejoin.body.participantCredential,
  });
  assert.equal(hostParticipants.status, 200);
  assert.equal(hostParticipants.body.participants?.length, 2);
  assert.equal(
    hostParticipants.body.participants?.some((item) => item.role === 'host'),
    true,
  );
  assert.equal(
    hostParticipants.body.participants?.some((item) => item.role === 'viewer'),
    true,
  );
  assert.equal(hostParticipants.body.participants?.[0]?.deviceId, undefined);
  assert.equal(typeof hostParticipants.body.participants?.[0]?.userId, 'string');

  const impersonatedHost = await post('/rooms/broadcast01/participants', {
    requesterParticipantId: creatorRejoin.body.participantId,
    participantCredential: viewer.body.participantCredential,
  });
  assert.equal(impersonatedHost.status, 403);

  const selfRemove = await post('/rooms/broadcast01/participants/remove', {
    requesterParticipantId: creatorRejoin.body.participantId,
    participantCredential: creatorRejoin.body.participantCredential,
    targetParticipantId: creatorRejoin.body.participantId,
  });
  assert.equal(selfRemove.status, 400);

  const broadcastOverviewResponse = await fetch(`${requireBaseUrl()}/api/overview`);
  const broadcastOverview = await broadcastOverviewResponse.json() as ApiBody;
  assert.equal(
    JSON.stringify(broadcastOverview).includes('participantCredential'),
    false,
  );
  assert.equal(
    JSON.stringify(broadcastOverview).includes('participantCredentialHash'),
    false,
  );
  assert.equal(
    JSON.stringify(broadcastOverview).includes('roomOwnerCredential'),
    false,
  );
  assert.equal(
    JSON.stringify(broadcastOverview).includes('roomOwnerCredentialHash'),
    false,
  );
  const broadcastRoom = broadcastOverview.rooms?.find((room) => room.roomCode === 'broadcast01');
  assert.equal(broadcastRoom?.roomMode, 'broadcast');
  assert.equal(
    broadcastRoom?.attendees?.some((attendee) => attendee.role === 'host'),
    true,
  );
  assert.equal(
    broadcastRoom?.attendees?.some((attendee) => attendee.role === 'viewer'),
    true,
  );

  const discoveredResponse = await fetch(`${requireBaseUrl()}/rooms/discover`, {
    headers: { 'X-Media-Backend-Contract': '1' },
  });
  assert.equal(discoveredResponse.status, 200);
  const discovered = await discoveredResponse.json() as ApiBody;
  const discoveredBroadcast = discovered.rooms?.find((room) => room.roomCode === 'broadcast01');
  assert.equal(discoveredBroadcast?.provider, 'livekit');
  assert.equal(discoveredBroadcast?.roomMode, 'broadcast');
  assert.equal(typeof discoveredBroadcast?.attendeeCount, 'number');
  assert.equal(discoveredBroadcast?.attendees, undefined);

  const hostClose = await post('/rooms/broadcast01/close', {
    requesterParticipantId: creatorRejoin.body.participantId,
    participantCredential: creatorRejoin.body.participantCredential,
  });
  assert.equal(hostClose.status, 200);
  assert.equal(
    liveKitRoomServiceCalls.includes('/twirp/livekit.RoomService/DeleteRoom'),
    true,
  );

  const retryRoom = await post('/rooms', {
    roomCode: 'deleteRetry1',
    displayName: 'Retry Host',
    userId: 'retry-host',
    roomMode: 'broadcast',
    deviceId: 'device-retry-001',
  });
  assert.equal(retryRoom.status, 200);
  failLiveKitDeleteRoom = true;
  const failedClose = await post('/rooms/deleteRetry1/close', {
    requesterParticipantId: retryRoom.body.participantId,
    participantCredential: retryRoom.body.participantCredential,
  });
  assert.equal(failedClose.status, 500);
  const afterFailedClose = await fetch(`${requireBaseUrl()}/api/overview`);
  const failedCloseOverview = await afterFailedClose.json() as ApiBody;
  assert.equal(
    failedCloseOverview.rooms?.some((room) => room.roomCode === 'deleteRetry1'),
    true,
    'failed provider deletion must keep the room directory entry for retry',
  );
  const discoverAfterFailedClose = await fetch(
    `${requireBaseUrl()}/rooms/discover`,
    { headers: { 'X-Media-Backend-Contract': '1' } },
  );
  const discoverAfterFailure = await discoverAfterFailedClose.json() as ApiBody;
  assert.equal(
    discoverAfterFailure.rooms?.some((room) => room.roomCode === 'deleteRetry1'),
    false,
    'partially closed rooms must not remain discoverable',
  );

  failLiveKitDeleteRoom = false;
  const retriedClose = await post('/rooms/deleteRetry1/close', {
    requesterParticipantId: retryRoom.body.participantId,
    participantCredential: retryRoom.body.participantCredential,
  });
  assert.equal(retriedClose.status, 200);
  const afterRetry = await fetch(`${requireBaseUrl()}/api/overview`);
  const retryOverview = await afterRetry.json() as ApiBody;
  assert.equal(
    retryOverview.rooms?.some((room) => room.roomCode === 'deleteRetry1'),
    false,
  );

  const closeableMeeting = await post('/rooms', {
    roomCode: 'meetClose1',
    displayName: 'Meeting Owner',
    userId: 'meeting-owner',
    roomMode: 'meeting',
    deviceId: 'device-meeting-close-001',
  });
  assert.equal(closeableMeeting.status, 200);
  assert.equal(closeableMeeting.body.role, 'participant');
  assert.ok(closeableMeeting.body.roomOwnerCredential);
  const closeMeeting = await post('/rooms/meetClose1/close', {
    requesterParticipantId: closeableMeeting.body.participantId,
    participantCredential: closeableMeeting.body.participantCredential,
    roomOwnerCredential: closeableMeeting.body.roomOwnerCredential,
  });
  assert.equal(closeMeeting.status, 200);

  const switched = await post('/api/provider', { provider: 'chime' });
  assert.equal(switched.status, 200);
  assert.equal(switched.body.activeProvider, 'aws');

  const joined = await post('/rooms/stickyRoom1/join', {
    userId: 'Guest',
  });
  assert.equal(joined.status, 200);
  assert.equal(joined.body.provider, 'livekit');
  assert.equal(joined.body.roomCode, 'stickyRoom1');

});


test('teacher plus two students and host plus two viewers share authenticated interaction state', async () => {
  await post('/api/provider', { provider: 'livekit' });
  const teacher = await post('/rooms', { roomCode: 'teachingE2E1', nickname: 'Teacher', userId: 'teacher-e2e', roomMode: 'meeting' });
  const alice = await post('/rooms/teachingE2E1/join', { userId: 'alice-e2e', displayName: 'Alice' });
  const bob = await post('/rooms/teachingE2E1/join', { userId: 'bob-e2e', displayName: 'Bob' });
  assert.equal(teacher.status, 200); assert.equal(alice.status, 200); assert.equal(bob.status, 200);
  const auth = (body: ApiBody) => ({ requesterParticipantId: body.participantId, participantCredential: body.participantCredential });
  const teacherAuth = { ...auth(teacher.body), roomOwnerCredential: teacher.body.roomOwnerCredential };
  const feedback = await post('/rooms/teachingE2E1/classroom/action', {
    ...auth(alice.body), action: 'feedback.send', kind: 'question',
    userId: 'bob-e2e', displayName: 'Forged', eventId: 'feedback-http-alice-1',
  });
  assert.equal(feedback.status, 200);
  assert.equal(feedback.body.feedback?.[0]?.userId, 'alice-e2e');
  assert.equal(feedback.body.feedback?.[0]?.displayName, 'Alice');
  const teacherFeedback = await post('/rooms/teachingE2E1/classroom/snapshot', teacherAuth);
  assert.equal(teacherFeedback.body.feedback?.[0]?.kind, 'question');
  assert.equal(teacherFeedback.body.feedbackSupported, true);
  assert.deepEqual((await post('/rooms/teachingE2E1/classroom/snapshot', auth(bob.body))).body.feedback, []);
  assert.equal((await post('/rooms/teachingE2E1/classroom/action', {
    requesterParticipantId: alice.body.participantId,
    action: 'feedback.send', kind: 'great',
  })).status, 403);
  assert.equal((await post('/rooms/teachingE2E1/classroom/action', {
    ...teacherAuth, action: 'feedback.send', kind: 'great',
  })).status, 403);
  const action = (credentials: object, name: string, payload: object) => post('/rooms/teachingE2E1/classroom/action', {
    ...credentials, action: `tool.${name}`, payload: JSON.stringify(payload),
  });
  const forged = await action(auth(alice.body), 'notice.publish', { kind: 'announcement', text: 'Forged' });
  assert.equal(forged.status, 403);
  const notice = await action(teacherAuth, 'notice.publish', { kind: 'announcement', text: 'Welcome class' });
  assert.equal(notice.status, 200);
  const bobState = await post('/rooms/teachingE2E1/classroom/snapshot', auth(bob.body));
  assert.equal((bobState.body.tools!.notices as Array<{text: string}>)[0]!.text, 'Welcome class');
  const quiz = await action(teacherAuth, 'activity.publish', { kind: 'quiz', title: '2+2?', options: ['3', '4'], correctOption: 1 });
  assert.equal(quiz.status, 200);
  const id = (quiz.body.tools!.activities as Array<{id: string}>)[0]!.id;
  const aliceState = await post('/rooms/teachingE2E1/classroom/snapshot', auth(alice.body));
  assert.ok(!('correctOption' in (aliceState.body.tools!.activities as object[])[0]!));
  assert.equal((await action(auth(alice.body), 'activity.answer', { activityId: id, option: 1 })).status, 200);
  assert.equal((await action(auth(bob.body), 'activity.answer', { activityId: id, option: 0 })).status, 200);
  const closed = await action(teacherAuth, 'activity.close', { activityId: id });
  assert.deepEqual((closed.body.tools!.activities as Array<{counts: number[]}>)[0]!.counts, [1, 1]);
  const source = await action(teacherAuth, 'annotation.source', { sourceKey: 'share-screen' });
  const canvasId = (source.body.tools!.annotation as {canvasId: string}).canvasId;
  const mark = await action(teacherAuth, 'annotation.begin', { canvasId, id: 'circle1', tool: 'circle', color: 0xffffaa00,
    width: 3, points: [{x: .1, y: .2}, {x: .5, y: .6}] });
  assert.equal(mark.status, 200);
  const received = await post('/rooms/teachingE2E1/classroom/snapshot', auth(bob.body));
  assert.equal((received.body.tools!.annotation as {shapes: object[]}).shapes.length, 1);
  type Content = ReturnType<typeof classroomToolsSnapshot>['content'];
  const contentOf = (body: ApiBody) => body.tools!.content as Content;
  const initialContent = contentOf(received.body);
  const boardMode = await action(teacherAuth, 'content.mode', { mode: 'whiteboard', expectedRevision: initialContent.revision });
  assert.equal(boardMode.status, 200);
  const board = contentOf(boardMode.body).whiteboard;
  const boardMarkPayload = { expectedRevision: board.revision, pageId: board.activePageId, canvasId: board.canvas.canvasId,
    id: 'board-arrow', tool: 'arrow', color: 0xffffaa00, width: 3, points: [{x:.2,y:.3},{x:.6,y:.7}] };
  const boardRequest = { ...teacherAuth, action:'tool.whiteboard.begin', payload:JSON.stringify(boardMarkPayload), eventId:'http-whiteboard-001' };
  const boardMark = await post('/rooms/teachingE2E1/classroom/action', boardRequest);
  assert.equal(boardMark.status, 200);
  assert.equal((await post('/rooms/teachingE2E1/classroom/action', boardRequest)).status, 200);
  assert.equal((await action(auth(alice.body), 'whiteboard.clear', boardMarkPayload)).status,403);
  for (const student of [alice.body, bob.body]) {
    const state = contentOf((await post('/rooms/teachingE2E1/classroom/snapshot',auth(student))).body);
    assert.equal(state.mode,'whiteboard'); assert.equal(state.canManage,false);
    assert.equal(state.whiteboard.canEdit,false); assert.equal(state.whiteboard.canvas.shapes.length,1);
  }
  await post('/rooms/teachingE2E1/leave',{participantId:bob.body.participantId});
  const rejoinedBob = await post('/rooms/teachingE2E1/join',{userId:'bob-e2e',displayName:'Bob'});
  const restored = contentOf((await post('/rooms/teachingE2E1/classroom/snapshot',auth(rejoinedBob.body))).body);
  assert.equal(restored.whiteboard.canvas.shapes[0]!.id,'board-arrow');
  assert.equal(restored.whiteboard.activePageId,board.activePageId);
  const addedPage = await action(teacherAuth,'whiteboard.page.add',{expectedRevision:restored.whiteboard.revision,title:'Exercise'});
  assert.equal(addedPage.status,200);
  const second = contentOf(addedPage.body).whiteboard;
  assert.equal((await action(teacherAuth,'whiteboard.begin',{...boardMarkPayload,expectedRevision:second.revision,id:'late'})).status,409);
  const selectedPage = await action(teacherAuth,'whiteboard.page.select',{expectedRevision:second.revision,pageId:board.activePageId});
  assert.equal(contentOf(selectedPage.body).whiteboard.canvas.shapes.length,1);
  const invalidCredential = await post('/rooms/teachingE2E1/classroom/snapshot', { ...auth(rejoinedBob.body), participantCredential: 'wrong' });
  assert.equal(invalidCredential.status, 403);

  const host = await post('/rooms', { roomCode: 'giftE2E1', nickname: 'Host', userId: 'gift-host', roomMode: 'broadcast' });
  const viewer1 = await post('/rooms/giftE2E1/join', { userId: 'viewer-1' });
  const viewer2 = await post('/rooms/giftE2E1/join', { userId: 'viewer-2' });
  assert.equal(host.body.liveInteractions, true); assert.equal(viewer2.body.liveInteractions, true);
  const giftBody = { ...auth(viewer1.body), giftId: 'star', quantity: 2, eventId: 'http-gift-001' };
  assert.equal((await post('/rooms/giftE2E1/live/gift', giftBody)).status, 200);
  assert.equal((await post('/rooms/giftE2E1/live/gift', giftBody)).status, 200);
  const likeBody = { ...auth(viewer1.body), eventId: 'http-like-001' };
  assert.equal((await post('/rooms/giftE2E1/live/like', likeBody)).status, 200);
  assert.equal((await post('/rooms/giftE2E1/live/like', likeBody)).status, 200);
  for (const person of [host.body, viewer2.body]) {
    const snapshot = await post('/rooms/giftE2E1/live/snapshot', auth(person));
    assert.equal(snapshot.status, 200); assert.equal(snapshot.body.totals!.star, 2);
    assert.equal(snapshot.body.totalLikes, 1);
    assert.equal(snapshot.body.likeEvents?.length, 1);
  }
  assert.equal((await post('/rooms/giftE2E1/live/like', { ...likeBody, participantCredential: 'wrong' })).status, 403);
  assert.equal((await post('/rooms/giftE2E1/live/gift', { ...giftBody, participantCredential: 'wrong' })).status, 403);
  await post('/rooms/teachingE2E1/close', teacherAuth);
  await post('/rooms/giftE2E1/close', auth(host.body));
});

function auth(body: ApiBody) {
  return {requesterParticipantId: body.participantId, participantCredential: body.participantCredential};
}
async function lesson(code: string) {
  await post('/api/provider', {provider: 'livekit'});
  const teacher = await post('/rooms', {roomCode: code, userId: `${code}-teacher`, nickname: 'Teacher', roomMode: 'meeting'});
  const student = await post(`/rooms/${code}/join`, {userId: `${code}-student`, displayName: 'Student'});
  assert.equal(teacher.status, 200); assert.equal(student.status, 200);
  const teacherAuth = {...auth(teacher.body), roomOwnerCredential: teacher.body.roomOwnerCredential};
  const action = (name: string, eventId?: string) => post(`/rooms/${code}/classroom/action`, {
    ...teacherAuth, action: name, userId: `${code}-student`, ...(eventId ? {eventId} : {}),
  });
  return {teacherAuth, student: student.body, action};
}

test('rejoining resets grants, revokes the old identity and preserves questions', async () => {
  const code = 'resetGrant1';
  const {teacherAuth, student, action} = await lesson(code);
  await action('speak.grant','prior-grant-1');
  await post(`/rooms/${code}/classroom/action`, {...auth(student), action:'question.ask', text:'Keep this question'});
  const before = await post(`/rooms/${code}/classroom/snapshot`, auth(student));
  assert.equal(before.body.students?.find(s => s.userId === `${code}-student`)?.canSpeak, true);
  const rejoined = await post(`/rooms/${code}/join`, {userId:`${code}-student`,displayName:'Student'});
  assert.equal(rejoined.status, 200);
  assert.notEqual(rejoined.body.participantId, student.participantId);
  assert.equal(liveKitUpdates.at(-1)?.identity, student.participantId);
  assert.ok(!liveKitUpdates.at(-1)?.permission.canPublishSources.includes('MICROPHONE'));
  const claims = JSON.parse(Buffer.from(rejoined.body.livekit!.token.split('.')[1]!, 'base64url').toString());
  assert.ok(!claims.video.canPublishSources.includes('microphone'));
  const state = await post(`/rooms/${code}/classroom/snapshot`, auth(rejoined.body));
  assert.equal(state.body.students?.find(s => s.userId === `${code}-student`)?.canSpeak, false);
  assert.equal(state.body.questions?.[0]?.text, 'Keep this question');
  const updates=liveKitUpdates.length;
  const replay=await action('speak.grant','prior-grant-1');
  assert.equal(replay.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,false);
  assert.equal(liveKitUpdates.length,updates);

  assert.equal((await post(`/rooms/${code}/classroom/snapshot`, auth(student))).status, 404);
  await post(`/rooms/${code}/close`, teacherAuth);
});

test('a failed old-identity revocation rejects rejoin without replacing its credential', async () => {
  const code='resetFail1'; const {teacherAuth, student, action}=await lesson(code);
  await action('speak.grant');
  failLiveKitUpdateParticipant=true;
  try {
    assert.equal((await post(`/rooms/${code}/join`,{userId:`${code}-student`,displayName:'Student'})).status,502);
    const snapshot=await post(`/rooms/${code}/classroom/snapshot`,auth(student));
    assert.equal(snapshot.status,200);
    assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,true);
  } finally { failLiveKitUpdateParticipant=false; }
  assert.equal((await post(`/rooms/${code}/join`,{userId:`${code}-student`,displayName:'Student'})).status,200);
  await post(`/rooms/${code}/close`,teacherAuth);
});

test('concurrent grant then revoke wait for the provider and finish revoked; duplicate events stay idempotent', async () => {
  const code='orderGr1'; const {teacherAuth, action}=await lesson(code);
  const gate=holdNextUpdate();
  const granted=action('speak.grant','ordered-grant-1');
  await gate.entered;
  let revokedSettled=false;
  const revoked=action('speak.revoke','ordered-revoke-1').then(result=>{revokedSettled=true;return result;});
  try { await new Promise(resolve=>setTimeout(resolve,50)); assert.equal(revokedSettled,false); }
  finally { gate.release(); }
  assert.equal((await granted).status,200); assert.equal((await revoked).status,200);
  assert.ok(!liveKitUpdates.at(-1)?.permission.canPublishSources.includes('MICROPHONE'));
  const count=liveKitUpdates.length;
  assert.equal((await action('speak.revoke','ordered-revoke-1')).status,200);
  assert.equal(liveKitUpdates.length,count);
  const snapshot=await post(`/rooms/${code}/classroom/snapshot`,teacherAuth);
  assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,false);
  await post(`/rooms/${code}/close`,teacherAuth);
});

test('join, leave, removal and close wait for an in-flight speaking update', async () => {
  for (const mode of ['join','close','leave','remove']) {
    const code=`ord${mode}1`; const {teacherAuth,student,action}=await lesson(code);
    const gate=holdNextUpdate(); const granted=action('speak.grant'); await gate.entered;
    let done=false;
    const next=post(`/rooms/${code}/${mode==='remove'?'participants/remove':mode}`,
      mode==='join'?{userId:`${code}-student`,displayName:'Student'}:
      mode==='leave'?{participantId:student.participantId}:
      mode==='remove'?{...teacherAuth,targetParticipantId:student.participantId}:teacherAuth)
      .then(value=>{done=true;return value;});
    try { await new Promise(resolve=>setTimeout(resolve,50)); assert.equal(done,false); }
    finally { gate.release(); }
    assert.equal((await granted).status,200); assert.equal((await next).status,200);
    if (mode==='join') {
      const snapshot=await post(`/rooms/${code}/classroom/snapshot`,teacherAuth);
      assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,false);
      assert.ok(!liveKitUpdates.at(-1)?.permission.canPublishSources.includes('MICROPHONE'));
      await post(`/rooms/${code}/close`,teacherAuth);
    } else if (mode==='leave' || mode==='remove') {
      const snapshot=await post(`/rooms/${code}/classroom/snapshot`,teacherAuth);
      assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,false);
      assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.online,false);
      await post(`/rooms/${code}/close`,teacherAuth);
    } else {
      const failed=await action('speak.grant'); assert.equal(failed.status,404);
    }
  }
});

test('a failed in-flight grant releases queued revocation and leaves the student denied', async () => {
  const code='failedOrder1'; const {teacherAuth,action}=await lesson(code);
  const gate=holdNextUpdate(); failLiveKitUpdateParticipant=true;
  const granted=action('speak.grant'); await gate.entered;
  const revoked=action('speak.revoke');
  try {
    gate.release();
    assert.equal((await granted).status,502);
    assert.equal((await revoked).status,200);
    const snapshot=await post(`/rooms/${code}/classroom/snapshot`,teacherAuth);
    assert.equal(snapshot.body.students?.find(s=>s.userId===`${code}-student`)?.canSpeak,false);
  } finally { failLiveKitUpdateParticipant=false; gate.release(); }
  assert.equal((await action('speak.grant')).status,200);
  await post(`/rooms/${code}/close`,teacherAuth);
});


test('standard meeting policy survives join and discovery without classroom microphone restrictions', async () => {
  await post('/api/provider', {provider: 'livekit'});
  const invalid = await post('/rooms', {roomCode: 'modeBad001', roomMode: 'broadcast', meetingMode: 'standard', nickname: 'Host'});
  assert.equal(invalid.status, 400);
  const created = await post('/rooms', {roomCode: 'standardSdk1', roomMode: 'meeting', meetingMode: 'standard', nickname: 'Host', userId: 'standard-host'});
  assert.equal(created.status, 200);
  assert.equal(created.body.meetingMode, 'standard');
  const member = await post('/rooms/standardSdk1/join', {userId: 'standard-member', displayName: 'Member', meetingMode: 'classroom'});
  assert.equal(member.status, 200);
  assert.equal(member.body.meetingMode, 'standard');
  const token = JSON.parse(Buffer.from(member.body.livekit!.token.split('.')[1]!, 'base64url').toString()) as {video: {canPublish: boolean; canPublishSources?: string[]}};
  assert.equal(token.video.canPublish, true);
  assert.ok(token.video.canPublishSources == null || token.video.canPublishSources.includes('microphone'));
  const rooms = await (await fetch(`${requireBaseUrl()}/rooms/discover`)).json() as ApiBody;
  assert.equal(rooms.rooms?.find(room => room.roomCode === 'standardSdk1')?.meetingMode, 'standard');
  const studentAuth = {requesterParticipantId: member.body.participantId, participantCredential: member.body.participantCredential};
  assert.equal((await post('/rooms/standardSdk1/classroom/action', {...studentAuth, action: 'hand.raise'})).status, 400);
  const hostAuth = {requesterParticipantId: created.body.participantId, participantCredential: created.body.participantCredential, roomOwnerCredential: created.body.roomOwnerCredential};
  const rejoined = await post('/rooms/standardSdk1/join', {userId: 'standard-host', displayName: 'Host', roomOwnerCredential: created.body.roomOwnerCredential});
  assert.equal(rejoined.body.meetingMode, 'standard');
  assert.equal(rejoined.body.roomOwnerCredential, created.body.roomOwnerCredential);
  assert.equal((await post('/rooms/standardSdk1/close', {...hostAuth, requesterParticipantId: rejoined.body.participantId, participantCredential: rejoined.body.participantCredential})).status, 200);
});

test('room-wide preventScreenCapture policy propagates from host creation to joining attendees', async () => {
  await post('/api/provider', {provider: 'livekit'});
  const invalid = await post('/rooms', {roomCode: 'secBad001', roomMode: 'meeting', preventScreenCapture: 'yes', nickname: 'Host'});
  assert.equal(invalid.status, 400);
  const created = await post('/rooms', {roomCode: 'secRoom01', roomMode: 'meeting', preventScreenCapture: true, nickname: 'Host', userId: 'sec-host'});
  assert.equal(created.status, 200);
  assert.equal((created.body as Record<string, unknown>).preventScreenCapture, true);
  const member = await post('/rooms/secRoom01/join', {userId: 'sec-member', displayName: 'Member'});
  assert.equal(member.status, 200);
  assert.equal((member.body as Record<string, unknown>).preventScreenCapture, true);
  const hostAuth = {requesterParticipantId: created.body.participantId, participantCredential: created.body.participantCredential, roomOwnerCredential: created.body.roomOwnerCredential};
  assert.equal((await post('/rooms/secRoom01/close', hostAuth)).status, 200);
});
