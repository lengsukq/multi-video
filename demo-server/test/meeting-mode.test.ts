import assert from 'node:assert/strict';
import test from 'node:test';
import { ClassroomStateDirectory } from '../classroom/classroom-state.ts';
import { createRoomProvisioner } from '../services/room-creation.ts';
import type { RoomEntry, ProviderAdapter } from '../types.ts';

function fixture() {
  const entry: RoomEntry = {
    provider: 'fake', roomCode: 'normal', roomMode: 'meeting', meetingMode: 'standard',
    createdAt: new Date().toISOString(), lastHeartbeatMs: Date.now(), classroomTeacherUserId: 'host',
    attendees: ['host', 'member', 'other'].map(id => ({attendeeId: id, userId: id,
      displayName: id, externalUserId: id, joinedAt: new Date().toISOString()})),
  };
  return {entry, directory: new ClassroomStateDirectory()};
}

test('standard meetings reject teaching commands while allowing all participants to share and edit whiteboards', () => {
  const {entry, directory} = fixture();
  const host = entry.attendees[0]!;
  const member = entry.attendees[1]!;
  for (const action of ['hand.raise', 'question.ask', 'feedback.send', 'speak.grant', 'tool.timer.start']) {
    assert.throws(() => directory.act(entry, member, false, {action}), /Teaching is disabled/);
  }
  let state = directory.snapshot(entry, true, 'host');
  state = directory.act(entry, host, true, {action: 'tool.content.mode', payload: JSON.stringify({mode: 'whiteboard', expectedRevision: state.tools.content.revision})});
  assert.equal(state.tools.content.mode, 'whiteboard');
  assert.equal(state.tools.content.whiteboard.canEdit, true);
  const viewed = directory.snapshot(entry, false, 'member');
  assert.equal(viewed.tools.content.mode, 'whiteboard');
  assert.equal(viewed.tools.content.whiteboard.canEdit, true);
  assert.equal(viewed.tools.content.canManage, true);
  const added = directory.act(entry, member, false, {action: 'tool.whiteboard.page.add', payload: JSON.stringify({title: 'Page 2', expectedRevision: viewed.tools.content.whiteboard.revision})});
  assert.equal(added.tools.content.whiteboard.pages.length, 2);
  const closed = directory.act(entry, member, false, {action: 'tool.content.mode', payload: JSON.stringify({mode: 'members', expectedRevision: added.tools.content.revision})});
  assert.equal(closed.tools.content.mode, 'members');
  const reopened = directory.act(entry, member, false, {action: 'tool.content.mode', payload: JSON.stringify({mode: 'whiteboard', expectedRevision: closed.tools.content.revision})});
  assert.equal(reopened.tools.content.mode, 'whiteboard');
});

test('ordinary members share screens and only the current sharer may annotate', () => {
  const {entry, directory} = fixture();
  const member = entry.attendees[1]!;
  const other = entry.attendees[2]!;
  const initial = directory.snapshot(entry, false, 'member');
  assert.equal(initial.tools.content.canShareScreen, true);
  const state = directory.act(entry, member, false, {action: 'tool.content.mode', payload: JSON.stringify({mode: 'screen', sourceKey: 'screen-1', expectedRevision: initial.tools.content.revision})});
  assert.equal(state.tools.content.screen.participantId, 'member');
  assert.equal(state.tools.content.canManage, true);
  const payload = JSON.stringify({canvasId: state.tools.content.screen.canvasId, embeddedInVideo: true});
  assert.throws(() => directory.act(entry, other, false, {action: 'tool.annotation.presentation', payload}), /Only the current screen sharer/);
  assert.throws(() => directory.act(entry, entry.attendees[0]!, true, {action: 'tool.annotation.presentation', payload}), /Only the current screen sharer/);
  assert.equal(directory.act(entry, member, false, {action: 'tool.annotation.presentation', payload}).tools.content.screen.embeddedInVideo, true);
  assert.throws(() => directory.requiresSpeakerProviderUpdate(entry, entry.attendees[0]!, true, {action: 'speak.grant', userId: 'member'}), /Teaching is disabled/);
});

test('teachers cannot invoke student-only classroom controls', () => {
  const {entry, directory} = fixture();
  entry.meetingMode = 'classroom';
  for (const action of ['hand.raise', 'hand.lower', 'question.ask', 'feedback.send']) {
    assert.throws(() => directory.act(entry, entry.attendees[0]!, true, {action}), /Only students/);
  }
});

test('recovering teacher authority removes an earlier student hand request', () => {
  const {entry, directory} = fixture();
  entry.meetingMode = 'classroom';
  delete entry.classroomTeacherUserId;
  directory.act(entry, entry.attendees[0]!, false, {action: 'hand.raise'});
  entry.classroomTeacherUserId = 'host';
  const state = directory.snapshot(entry, true, 'host');
  assert.equal(state.stats.handsRaised, 0);
  assert.equal(state.students.find(person => person.userId === 'host')?.handRaised, false);
});

test('room provisioning returns and stores mode without touching provider selection', async () => {
  for (const mode of ['standard', 'classroom', undefined] as const) {
    const {entry} = fixture();
    delete entry.meetingMode;
    let requestedCode = '';
    const provider = {id: 'fake', displayName: 'Fake', setClassroomMicrophonePermission: async () => {},
      createRoom: async ({roomCode}: {roomCode: string}) => { requestedCode = roomCode; return {entry, response: {contractVersion: 1, provider: 'fake', roomCode, role: 'participant'}}; },
    } as unknown as ProviderAdapter;
    const provision = createRoomProvisioner({chatProviderRegistry: {} as never, publicProviderId: id => id,
      mediaManagementCapabilities: () => ({listParticipants: false, removeParticipant: false, closeRoom: false, muteParticipant: false, stopParticipantVideo: false, changeParticipantRole: false}), registerRoom: () => {}, logEvent: () => {}});
    const result = await provision({roomCode: 'normal', roomMode: 'meeting', meetingMode: mode, role: 'participant', provider, selectedChatProvider: null});
    assert.equal(requestedCode, 'normal');
    assert.equal(result.created.entry.meetingMode, mode);
    assert.equal(result.created.response.meetingMode, mode);
    assert.equal(result.created.entry.classroomSpeakEnforcement, mode === 'standard' ? undefined : 'provider');
  }
});
