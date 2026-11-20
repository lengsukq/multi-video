import type { ProviderAdapter, ChatProviderAdapter, RoomEntry, RoomAttendee, MediaRole, RoomMode } from '../../types.ts';
import type { ProviderRegistry } from '../../providers/provider-registry.ts';
import type { RoomDirectory } from '../../providers/room-directory.ts';
import type { ChatProviderRegistry } from '../../chat/chat-provider-registry.ts';
import type { ChatRoomDirectory } from '../../chat/chat-room-directory.ts';
import type { ClassroomStateDirectory } from '../../classroom/classroom-state.ts';
import { requireParticipantCredential, issueParticipantCredential } from '../../participant-credential.ts';
import { matchesRoomOwnerCredential } from '../../room-owner-credential.ts';
import { ProviderOperationError } from '../../providers/provider-registry.ts';
import { requireRoomManager } from '../../room-access.ts';
import { createRoomProvisioner } from '../../services/room-creation.ts';

import type { RoomApplicationDependencies } from './dependencies.ts';
import { fail, reply, replyStatus, type ApplicationInput, type ApplicationReply } from '../application-protocol.ts';

export async function postRooms(input: ApplicationInput, dependencies: Pick<RoomApplicationDependencies, 'roomDirectory' | 'chatProviderRegistry' | 'classroomDirectory' | 'currentProvider' | 'currentChatProvider' | 'withRoomOperation' | 'assertRoomOpen' | 'bindLogicalIdentity' | 'normalizeRoomCode' | 'normalizeDeviceId' | 'normalizeUserId' | 'parseRole' | 'parseRoomMode' | 'creatorRoleForMode' | 'generateRoomCode' | 'engineProviderForSelection' | 'publicProviderId' | 'exposeVendorResponse' | 'registerRoom' | 'assertRole' | 'mediaManagementCapabilities' | 'closeRoomUnlocked' | 'logEvent'>): Promise<ApplicationReply> {
const { roomDirectory, chatProviderRegistry, classroomDirectory, currentProvider, currentChatProvider, withRoomOperation, assertRoomOpen, bindLogicalIdentity, normalizeRoomCode, normalizeDeviceId, normalizeUserId, parseRole, parseRoomMode, creatorRoleForMode, generateRoomCode, engineProviderForSelection, publicProviderId, exposeVendorResponse, registerRoom, assertRole, mediaManagementCapabilities, closeRoomUnlocked, logEvent } = dependencies;
const provisionRoom = createRoomProvisioner({
    chatProviderRegistry,
    publicProviderId,
    mediaManagementCapabilities,
    registerRoom,
    logEvent,
  });

  try {
    const avatarUrl = normalizeAvatarUrl(input.body?.avatarUrl);
    let roomCode = normalizeRoomCode(input.body?.roomCode);
    if (input.body?.roomCode && !roomCode) {
      return fail( 400, 'bad-room-code', 'roomCode must be 4-12 letters/digits.');
    }
    if (roomCode && roomDirectory.has(roomCode)) {
      return fail( 409, 'room-exists', 'The room code is already in use.');
    }
    roomCode ??= generateRoomCode();

    const requestedRole = input.body?.role == null ? null : parseRole(input.body.role);
    if (input.body?.role != null && !requestedRole) {
      return fail( 400, 'invalid-argument', 'role must be participant, host, or viewer.');
    }
    const requestedRoomMode = parseRoomMode(input.body?.roomMode);
    if (input.body?.roomMode != null && !requestedRoomMode) {
      return fail( 400, 'invalid-argument', 'roomMode must be meeting or broadcast.');
    }
    const roomMode: RoomMode =
      requestedRoomMode ?? (requestedRole === 'host' || requestedRole === 'viewer' ? 'broadcast' : 'meeting');
    const meetingMode = input.body?.meetingMode;
    if (meetingMode != null && (!['standard', 'classroom'].includes(String(meetingMode)) || roomMode !== 'meeting')) return fail(400, 'invalid-argument', 'meetingMode requires a meeting and must be standard or classroom.');
    const rawPreventScreenCapture = input.body?.preventScreenCapture;
    if (rawPreventScreenCapture != null && typeof rawPreventScreenCapture !== 'boolean') {
      return fail(400, 'invalid-argument', 'preventScreenCapture must be a boolean.');
    }
    const derivedCreatorRole = creatorRoleForMode(roomMode);
    if (requestedRoomMode && requestedRole && requestedRole !== derivedCreatorRole) {
      return fail(
        400,
        'invalid-argument',
        `role is assigned by roomMode; ${roomMode} rooms are created as ${derivedCreatorRole}.`,
      );
    }
    const role = requestedRoomMode ? derivedCreatorRole : requestedRole ?? derivedCreatorRole;
    const deviceId = normalizeDeviceId(input.body?.deviceId);
    if (input.body?.deviceId != null && !deviceId) {
      return fail(
        400,
        'invalid-argument',
        'deviceId must be 8-128 letters, digits, dots, underscores, colons, or hyphens.',
      );
    }

    const provider = engineProviderForSelection(currentProvider(), roomMode);
    assertRole(provider, role);
    if (roomMode === 'broadcast') {
      assertRole(provider, 'viewer');
    }
    const rawNickname = input.body?.displayName?.trim() || input.body?.nickname?.trim() || null;
    const { created, roomOwnerCredential } = await provisionRoom({
      roomCode, roomMode, meetingMode: meetingMode as 'standard' | 'classroom' | undefined, preventScreenCapture: rawPreventScreenCapture === true, role, provider,
      selectedChatProvider: currentChatProvider(),
    });

    return await withRoomOperation(created.entry, async () => {
      try {
      assertRoomOpen(created.entry);
      if (!rawNickname) return reply(exposeVendorResponse(created.response));

      const userId = normalizeUserId(
        input.body?.userId ?? deviceId ?? rawNickname,
      );
      if (roomMode === 'meeting') created.entry.classroomTeacherUserId = userId;
      const response = await provider.joinRoom({
        entry: created.entry,
        rawName: rawNickname,
        role,
        userId,
        deviceId,
        classroomMicrophoneAllowed: true,
    });
    if (created.entry.chatProvider) response.chatProvider = created.entry.chatProvider;
    response.roomMode = roomMode;
    if (created.entry.meetingMode) response.meetingMode = created.entry.meetingMode;
    if (created.entry.preventScreenCapture) response.preventScreenCapture = true;
    if (roomMode === 'broadcast') response.liveInteractions = true;
    if (roomOwnerCredential) {
      response.roomOwnerCredential = roomOwnerCredential;
    }
    bindLogicalIdentity(
      created.entry,
      response.participantId,
      userId,
      rawNickname,
      deviceId,
      'host',
    );
    const joinedPerson = created.entry.attendees.find(person => person.attendeeId === response.participantId);
    if (joinedPerson) joinedPerson.avatarUrl = avatarUrl;
    response.participantCredential = issueParticipantCredential(
      created.entry,
      response.participantId,
    );
    roomDirectory.flush();
    if (roomMode === 'meeting' && created.entry.meetingMode !== 'standard') {
      classroomDirectory.snapshot(created.entry, true, userId);
    }
    logEvent('join', `${response.displayName} created+joined room ${roomCode} via ${provider.displayName}`);
    return reply(exposeVendorResponse({...response, avatarUrl, participantProfiles: publicParticipantProfiles(created.entry)}));
      } catch (error) {
        // Creation already reserved the code. A failed initial participant
        // join must release both the provider room and local directory entry.
        try {
          await closeRoomUnlocked(created.entry, 'initial creator join failed');
        } catch (rollbackError) {
          console.error('new room rollback failed', rollbackError);
        }
        throw error;
      }
    });
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    console.error('create room failed', error);
    const name = error instanceof Error ? error.name : String(error);
    logEvent('error', `create room failed: ${name}`);
    fail( 500, 'create-room-failed', 'Unable to create the room.');
  }

}
import { normalizeAvatarUrl, publicParticipantProfiles } from '../participant-profile.ts';
