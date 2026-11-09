import assert from 'node:assert/strict';
import {test} from 'node:test';

import {issueParticipantCredential} from '../participant-credential.ts';
import {issueRoomOwnerCredential} from '../room-owner-credential.ts';
import {ProviderOperationError} from '../providers/provider-registry.ts';
import {postRoomsByCodeClose} from '../services/room/post-rooms-by-code-close.ts';
import type {ApplicationInput} from '../services/application-protocol.ts';
import type {RoomApplicationDependencies} from '../services/room/dependencies.ts';
import type {RoomEntry} from '../types.ts';

function setup(role: 'host' | 'participant') {
  const entry = {
    roomCode: 'classroom-close-test',
    roomMode: 'meeting',
    provider: 'livekit',
    attendees: [{
      attendeeId: 'local-1',
      externalUserId: 'user-1',
      role,
      joinedAt: new Date().toISOString(),
    }],
    createdAt: new Date().toISOString(),
    lastHeartbeatMs: Date.now(),
  } as RoomEntry;
  const credential = issueParticipantCredential(entry, 'local-1');
  const owner = issueRoomOwnerCredential(entry);
  const calls: string[] = [];
  let failed = false;
  const dependencies = {
    contractVersion: 1,
    resolveRoom: async (code: unknown) => code === entry.roomCode ? entry : null,
    withRoomOperation: async (_room: RoomEntry, action: () => Promise<unknown>) => action(),
    closeRoomUnlocked: async (_room: RoomEntry, reason: string) => {
      calls.push(reason);
      if (failed) throw new Error('LiveKit DeleteRoom transient HTTP 502');
    },
  } as unknown as RoomApplicationDependencies;
  const request: ApplicationInput = {
    params: {code: entry.roomCode},
    query: {},
    body: {requesterParticipantId: 'local-1', participantCredential: credential},
  };
  return {dependencies, request, calls, owner, setFailed: (x: boolean) => {failed = x;}};
}

test('an RTC host may end a classroom for all participants', async () => {
  const {dependencies, request, calls} = setup('host');
  const result = await postRoomsByCodeClose(request, dependencies);
  assert.equal(result.status, 200);
  assert.equal((result.body as {closed: boolean}).closed, true);
  assert.deepEqual(calls, ['host close']);
});

test('a logical owner with participant RTC role can end the classroom', async () => {
  const {dependencies, request, calls, owner} = setup('participant');
  await assert.rejects(postRoomsByCodeClose(request, dependencies),
    (error: unknown) => error instanceof ProviderOperationError &&
      error.status === 403);
  assert.deepEqual(calls, [], 'denied caller never reaches the provider');
  const result = await postRoomsByCodeClose({
    ...request, body: {...request.body, roomOwnerCredential: owner},
  }, dependencies);
  assert.equal(result.status, 200);
  assert.deepEqual(calls, ['host close']);
});

test('provider close error preserves the retryable room and exposes its stage', async () => {
  const {dependencies, request, calls, setFailed} = setup('host');
  setFailed(true);
  const originalError = console.error;
  console.error = () => {};
  try {
    await assert.rejects(postRoomsByCodeClose(request, dependencies),
      (error: unknown) => {
        if (!(error instanceof ProviderOperationError)) return false;
        assert.equal(error.status, 500);
        assert.equal(error.code, 'close-failed');
        assert.deepEqual(error.details, {stage: 'closeProviderRoom'});
        return true;
      });
  } finally {
    console.error = originalError;
  }
  setFailed(false);
  assert.equal((await postRoomsByCodeClose(request, dependencies)).status, 200);
  assert.deepEqual(calls, ['host close', 'host close']);
});
