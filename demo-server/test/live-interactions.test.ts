import assert from 'node:assert/strict';
import test from 'node:test';
import { ClassroomStateDirectory } from '../classroom/classroom-state.ts';
import { SharedContentDirectory } from '../classroom/shared-content-directory.ts';
import { LiveInteractionDirectory } from '../live/live-interactions.ts';
import { createIvsProvider } from '../providers/ivs.ts';
import type { IvsRoomEntry, RoomEntry } from '../types.ts';
const fixture = () => {
  const entry: RoomEntry = { provider: 'ivs', roomCode: 'live123', roomMode: 'broadcast',
    createdAt: new Date().toISOString(), lastHeartbeatMs: Date.now(), attendees: [
      { attendeeId: 'host1', userId: 'host', externalUserId: 'host', role: 'host', joinedAt: new Date().toISOString() },
      { attendeeId: 'v1', userId: 'alice', externalUserId: 'alice', role: 'viewer', joinedAt: new Date().toISOString() },
      { attendeeId: 'v2', userId: 'bob', externalUserId: 'bob', role: 'viewer', joinedAt: new Date().toISOString() },
    ] };
  return { entry, directory: new LiveInteractionDirectory() };
};
test('gifts work independently of chat, with authority, replay protection and shared totals', () => {
  const { entry, directory } = fixture();
  const alice = entry.attendees[1]!, bob = entry.attendees[2]!;
  const request = { giftId: 'star', quantity: 5, eventId: 'gift-event-001' };
  const first = directory.send(entry, alice, request);
  assert.equal(first.totals.star, 5);
  assert.equal(first.events[0]?.recipientId, 'host');
  assert.equal(directory.send(entry, alice, request).revision, first.revision);
  assert.throws(() => directory.send(entry, alice, { ...request, quantity: 6 }), /Reused eventId/);
  directory.send(entry, bob, { giftId: 'flower', quantity: 2, eventId: 'gift-event-002' });
  const joined = directory.snapshot(entry, bob);
  assert.deepEqual(joined.totals, { star: 5, flower: 2 });
  assert.equal(joined.events.length, 2);
  assert.equal(first.events.length, 1);
});
test('likes are room-wide, credential-scoped, idempotent and share gift revision sequence', () => {
  const { entry, directory } = fixture();
  const alice = entry.attendees[1]!, bob = entry.attendees[2]!;
  const first = directory.sendLike(entry, alice, { eventId: 'like-event-001' });
  assert.equal(first.totalLikes, 1);
  assert.equal(directory.sendLike(entry, alice, { eventId: 'like-event-001' }).revision, first.revision);
  assert.equal(directory.snapshot(entry, bob).totalLikes, 1);
  assert.equal(directory.snapshot(entry, bob).likeEvents[0]?.userId, 'alice');
  const gift = directory.send(entry, bob, { giftId: 'star', quantity: 1, eventId: 'gift-event-001' });
  assert.equal(gift.revision, 2);
  const second = directory.sendLike(entry, bob, { eventId: 'like-event-002' });
  assert.equal(second.totalLikes, 2);
  assert.equal(second.revision, 3);
  assert.deepEqual(second.likeEvents.map(like => like.sequence), [1, 3]);
  assert.throws(() => directory.sendLike(entry, bob, { eventId: 'like-event-001' }), /Reused eventId/);
  assert.throws(() => directory.sendLike(entry, bob, { eventId: 'bad' }), /eventId/);
  for (let index = 0; index < 29; index++) {
    directory.sendLike(entry, bob, { eventId: `rate-like-${index.toString().padStart(4, '0')}` });
  }
  assert.throws(() => directory.sendLike(entry, bob, { eventId: 'rate-like-overflow' }), /wait/);
  assert.equal(directory.snapshot(entry, alice).totalLikes, 31);
});
test('invalid, excessive and offline-host gifts fail without incrementing totals', () => {
  const { entry, directory } = fixture();
  const alice = entry.attendees[1]!;
  for (const quantity of [0, -1, 100, 1.5, '1']) assert.throws(() => directory.send(entry, alice,
    { giftId: 'star', quantity, eventId: 'bad-gift-001' }), /quantity/);
  assert.throws(() => directory.send(entry, alice, { giftId: 'money', quantity: 1, eventId: 'bad-gift-001' }), /Unknown gift/);
  for (let i = 0; i < 20; i++) directory.send(entry, alice, {
    giftId: 'star', quantity: 1, eventId: `gift-event-${i.toString().padStart(3, '0')}`,
  });
  assert.throws(() => directory.send(entry, alice, {
    giftId: 'star', quantity: 1, eventId: 'gift-event-021',
  }), /combo paused/);
  assert.equal(directory.snapshot(entry, alice).totals.star, 20);
  entry.attendees.shift();
  assert.equal(directory.snapshot(entry, alice).canSendGift, false);
  assert.throws(() => directory.send(entry, alice, { giftId: 'star', quantity: 1, eventId: 'gift-event-offline' }), /offline/);
  assert.throws(() => directory.snapshot({ ...entry, roomMode: 'meeting' }, alice), /broadcast/);
});

test('co-host requests promote viewer role to participant and revert on end', () => {
  const { entry, directory } = fixture();
  const host = entry.attendees[0]!;
  const alice = entry.attendees[1]!;
  const requested = directory.requestCohost(entry, alice);
  assert.equal(requested.cohostSupported, true);
  assert.equal(requested.selfCohostStatus, 'requested');
  assert.equal(requested.cohostRequests.length, 1);

  assert.throws(() => directory.respondCohost(entry, alice, 'alice', 'approve'), /Host/);
  const approved = directory.respondCohost(entry, host, 'alice', 'approve');
  assert.equal(alice.role, 'participant');
  assert.equal(approved.activeCohosts.length, 1);
  assert.equal(directory.snapshot(entry, alice).selfCohostStatus, 'active');

  const ended = directory.respondCohost(entry, host, 'alice', 'end');
  assert.equal(alice.role, 'viewer');
  assert.equal(ended.activeCohosts.length, 0);
  assert.equal(directory.snapshot(entry, alice).selfCohostStatus, 'none');
});

test('broadcast rooms support host whiteboard while blocking classroom actions', () => {
  const { entry } = fixture();
  const host = entry.attendees[0]!;
  const alice = entry.attendees[1]!;
  const content = new SharedContentDirectory(new ClassroomStateDirectory());
  const initial = content.snapshot(entry, alice, false);
  assert.equal(initial.content.canManage, false);
  assert.throws(
    () => content.act(entry, host, true, { action: 'hand.raise' }),
    /content and whiteboard/,
  );
  const opened = content.act(entry, host, true, {
    action: 'tool.content.mode',
    payload: JSON.stringify({ mode: 'whiteboard', expectedRevision: initial.content.revision }),
  });
  assert.equal(opened.content.mode, 'whiteboard');
  assert.equal(content.snapshot(entry, alice, false).content.whiteboard.canEdit, false);
});

test('IVS issues and revokes auxiliary #content screen-share tokens for publishers', async () => {
  const disconnected: string[] = [];
  const ivs = createIvsProvider({
    contractVersion: 1,
    normalizeDisplayName: (v) => String(v ?? '').trim(),
    api: {
      async createStage(name) { return { arn: `arn:aws:ivs:us-east-1:123:stage/${name}` }; },
      async createParticipantToken({ userId, capabilities }) {
        return { token: `tok:${userId}`, participantId: `pid:${userId}`, capabilities: capabilities ?? ['PUBLISH'] };
      },
      async deleteStage() {},
      async disconnectParticipant(_arn, participantId) { disconnected.push(participantId); },
    },
  });
  const created = await ivs.createRoom({ roomCode: 'ivsaux', role: 'host' });
  const entry = created.entry as IvsRoomEntry;
  await ivs.joinRoom({ entry, rawName: 'Host', role: 'host', userId: 'host-1' });
  await ivs.joinRoom({ entry, rawName: 'Viewer', role: 'viewer', userId: 'viewer-1' });
  await assert.rejects(
    ivs.issueAuxiliaryMediaToken!({ entry, participantId: 'viewer-1', purpose: 'screen_share', action: 'acquire' }),
    /Viewers cannot/,
  );
  const acquired = await ivs.issueAuxiliaryMediaToken!({
    entry, participantId: 'host-1', purpose: 'screen_share', action: 'acquire',
  }) as { ivs: { capabilities: string[]; token: string } };
  assert.deepEqual(acquired.ivs.capabilities, ['PUBLISH']);
  assert.equal(acquired.ivs.token, 'tok:host-1#content');
  await ivs.issueAuxiliaryMediaToken!({
    entry, participantId: 'host-1', purpose: 'screen_share', action: 'revoke',
  });
  assert.deepEqual(disconnected, ['pid:host-1#content']);
});
