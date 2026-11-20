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

export async function postRoomsByCodeJoin(input: ApplicationInput, dependencies: Pick<RoomApplicationDependencies, 'roomDirectory' | 'providerRegistry' | 'classroomDirectory' | 'resolveRoom' | 'withRoomOperation' | 'assertRoomOpen' | 'isRoomPartiallyClosed' | 'bindLogicalIdentity' | 'normalizeDeviceId' | 'normalizeDisplayName' | 'normalizeUserId' | 'parseRole' | 'joinRoleForRoom' | 'exposeVendorResponse' | 'assertRole' | 'mediaManagementCapabilities' | 'logEvent'>): Promise<ApplicationReply> {
const { roomDirectory, providerRegistry, classroomDirectory, resolveRoom, withRoomOperation, assertRoomOpen, isRoomPartiallyClosed, bindLogicalIdentity, normalizeDeviceId, normalizeDisplayName, normalizeUserId, parseRole, joinRoleForRoom, exposeVendorResponse, assertRole, mediaManagementCapabilities, logEvent } = dependencies;


  try {
    const avatarUrl = normalizeAvatarUrl(input.body?.avatarUrl);
    const entry = await resolveRoom(input.params.code);
    if (!entry) {
      logEvent('error', `join ${input.params.code} failed: not found`);
      return fail( 404, 'room-not-found', 'The requested room was not found.');
    }
    return await withRoomOperation(entry, async () => {
      assertRoomOpen(entry);
      if (isRoomPartiallyClosed(entry)) {
        return fail(
          409,
          'room-closing',
          'The room is partially closed and is waiting for cleanup retry.',
        );
      }
      const provider = providerRegistry.requireConfigured(entry.provider);
      const deviceId = normalizeDeviceId(input.body?.deviceId);
      if (input.body?.deviceId != null && !deviceId) {
        return fail(
          400,
          'invalid-argument',
          'deviceId must be 8-128 letters, digits, dots, underscores, colons, or hyphens.',
        );
      }
      const displayName = normalizeDisplayName(
        input.body?.displayName ?? input.body?.nickname ?? input.body?.userId,
      );
      if (!displayName) {
        return fail( 400, 'invalid-argument', 'displayName or userId is required.');
      }
      const userId = normalizeUserId(input.body?.userId ?? deviceId ?? displayName);
      const requestedRole = input.body?.role == null ? null : parseRole(input.body.role);
      if (input.body?.role != null && !requestedRole) {
        return fail( 400, 'invalid-argument', 'role must be participant, host, or viewer.');
      }
      const role = entry.roomMode
        ? joinRoleForRoom(entry, input.body?.roomOwnerCredential)
        : requestedRole ?? 'participant';
      assertRole(provider, role, entry);
      if (entry.roomMode === 'meeting' && entry.meetingMode !== 'standard') {
        const previous = new Set(entry.attendees.filter(person =>
          person.userId !== entry.classroomTeacherUserId && person.role !== 'host' &&
          (person.userId === userId || (deviceId && person.deviceId === deviceId)))
          .map(person => person.attendeeId));
        // Losing the reference heartbeat is not proof the RTC stream stopped.
        const remembered = classroomDirectory.previousParticipantId(entry, userId);
        if (remembered && userId !== entry.classroomTeacherUserId) previous.add(remembered);
        for (const participantId of previous) {
          if (provider.setClassroomMicrophonePermission) {
            try {
              await provider.setClassroomMicrophonePermission(entry, participantId, false);
            } catch {
              throw new ProviderOperationError(502, 'classroom-control-failed',
                'Unable to revoke the previous participant microphone. Please retry joining.');
            }
          }
          classroomDirectory.resetParticipant(entry, participantId);
        }
      }
      const response = await provider.joinRoom({
        entry,
        rawName: displayName,
        role,
        userId,
        deviceId,
        classroomMicrophoneAllowed: entry.roomMode !== 'meeting' || entry.meetingMode === 'standard' ||
          Boolean(
            String(input.body?.roomOwnerCredential ?? '').trim() &&
            matchesRoomOwnerCredential(entry, String(input.body.roomOwnerCredential).trim()),
          ),
    });
    if (entry.chatProvider) response.chatProvider = entry.chatProvider;
    if (entry.roomMode) response.roomMode = entry.roomMode;
    if (entry.meetingMode) response.meetingMode = entry.meetingMode;
    if (entry.preventScreenCapture) response.preventScreenCapture = true;
    if (entry.roomMode === 'broadcast') response.liveInteractions = true;
    response.management = mediaManagementCapabilities(provider);
    const presentedOwnerCredential = String(
      input.body?.roomOwnerCredential ?? '',
    ).trim();
    if (
      presentedOwnerCredential &&
      matchesRoomOwnerCredential(entry, presentedOwnerCredential)
    ) {
      response.roomOwnerCredential = presentedOwnerCredential;
      if (entry.roomMode === 'meeting') entry.classroomTeacherUserId = userId;
    }
    bindLogicalIdentity(
      entry,
      response.participantId,
      userId,
      displayName,
      deviceId,
      role,
    );
    const joinedPerson = entry.attendees.find(person => person.attendeeId === response.participantId);
    if (joinedPerson) joinedPerson.avatarUrl = avatarUrl;
    response.participantCredential = issueParticipantCredential(
      entry,
      response.participantId,
    );
    roomDirectory.flush();
    if (entry.roomMode === 'meeting' && entry.meetingMode !== 'standard') {
      classroomDirectory.snapshot(
        entry, Boolean(response.roomOwnerCredential), userId,
      );
    }
    logEvent('join', `${response.displayName} joined room ${entry.roomCode} via ${provider.displayName}`);
    return reply(exposeVendorResponse({...response, avatarUrl, participantProfiles: publicParticipantProfiles(entry)}));
    });
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    console.error('room join failed', error);
    const name = error instanceof Error ? error.name : String(error);
    logEvent('error', `join room failed: ${name}`);
    fail( 500, 'join-failed', 'Unable to join the room.');
  }

}
import { normalizeAvatarUrl, publicParticipantProfiles } from '../participant-profile.ts';
