import type { RoomEntry } from '../../types.ts';
import { ProviderOperationError, type ProviderRegistry } from '../../providers/provider-registry.ts';
import type { ClassroomStateDirectory } from '../../classroom/classroom-state.ts';
import type { SharedContentDirectory } from '../../classroom/shared-content-directory.ts';
import type { LiveInteractionDirectory } from '../../live/live-interactions.ts';
import { requireParticipantCredential } from '../../participant-credential.ts';
import { matchesRoomOwnerCredential } from '../../room-owner-credential.ts';
import { fail, reply, type ApplicationInput, type ApplicationReply } from '../application-protocol.ts';

export interface InteractionApplicationDependencies {
  resolveRoom(ref: unknown): Promise<RoomEntry | null>;
  withRoomOperation<T>(entry: RoomEntry, action: () => Promise<T> | T): Promise<T>;
  assertRoomOpen(entry: RoomEntry): void;
  isRoomPartiallyClosed(entry: RoomEntry): boolean;
  pruneStaleAttendees(entry: RoomEntry, now: number, insideOperation?: boolean): void;
  classroomDirectory: ClassroomStateDirectory;
  sharedContentDirectory?: SharedContentDirectory;
  liveInteractionDirectory: LiveInteractionDirectory;
  providerRegistry: ProviderRegistry;
  logError?(message: string, error: unknown): void;
}

async function withAuthenticatedRoom<T>(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
  action: (entry: RoomEntry, attendee: ReturnType<typeof requireParticipantCredential>) => Promise<T> | T,
): Promise<T> {
  const entry = await dependencies.resolveRoom(input.params.code);
  if (!entry) fail(404, 'room-not-found', 'The requested room was not found.');
  return dependencies.withRoomOperation(entry, async () => {
    dependencies.assertRoomOpen(entry);
    if (dependencies.isRoomPartiallyClosed(entry)) {
      fail(409, 'room-closing', 'The room is closing.');
    }
    dependencies.pruneStaleAttendees(entry, Date.now(), true);
    const attendee = requireParticipantCredential(
      entry,
      String(input.body.requesterParticipantId ?? '').trim(),
      input.body.participantCredential,
    );
    return action(entry, attendee);
  });
}

export async function postClassroomSnapshot(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
): Promise<ApplicationReply> {
  try {
    const result = await withAuthenticatedRoom(input, dependencies, (entry, attendee) => {
      const proof = String(input.body.roomOwnerCredential ?? '').trim();
      if (proof && !matchesRoomOwnerCredential(entry, proof)) {
        fail(403, 'forbidden', 'Invalid room owner credential.');
      }
      return dependencies.classroomDirectory.snapshot(
        entry, Boolean(proof), attendee.userId ?? attendee.externalUserId,
      );
    });
    return reply(result);
  } catch (error) {
    if (error instanceof ProviderOperationError && error.code !== 'classroom-control-failed') throw error;
    dependencies.logError?.('classroom control request failed', error);
    fail(502, 'classroom-control-failed', 'Unable to apply the classroom action. Please retry.');
  }
}

export async function postClassroomAction(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
): Promise<ApplicationReply> {
  try {
    const result = await withAuthenticatedRoom(input, dependencies, async (entry, attendee) => {
      const proof = String(input.body.roomOwnerCredential ?? '').trim();
      if (proof && !matchesRoomOwnerCredential(entry, proof)) {
        fail(403, 'forbidden', 'Invalid room owner credential.');
      }
      const isTeacher = Boolean(proof);
      if (['speak.grant', 'speak.revoke'].includes(String(input.body.action ?? ''))) {
        if (!isTeacher) fail(403, 'forbidden', 'Teacher permission required.');
        dependencies.classroomDirectory.snapshot(
          entry, isTeacher, attendee.userId ?? attendee.externalUserId,
        );
        const shouldApply = dependencies.classroomDirectory.requiresSpeakerProviderUpdate(
          entry, attendee, isTeacher, input.body,
        );
        const targetUserId = String(input.body.userId ?? '').trim();
        const target = entry.attendees.find(
          (person) => (person.userId ?? person.externalUserId) === targetUserId,
        );
        if (!target) fail(404, 'participant-not-found', 'Target student is not online.');
        if (targetUserId === entry.classroomTeacherUserId) {
          fail(403, 'forbidden', 'Teacher microphone cannot be changed here.');
        }
        const provider = dependencies.providerRegistry.requireConfigured(entry.provider);
        if (shouldApply && provider.setClassroomMicrophonePermission) {
          await provider.setClassroomMicrophonePermission(
            entry, target.attendeeId, input.body.action === 'speak.grant',
          );
        }
      }
      return dependencies.classroomDirectory.act(entry, attendee, isTeacher, input.body);
    });
    return reply(result);
  } catch (error) {
    if (error instanceof ProviderOperationError && error.code !== 'classroom-control-failed') throw error;
    dependencies.logError?.('classroom control request failed', error);
    fail(502, 'classroom-control-failed', 'Unable to apply the classroom action. Please retry.');
  }
}

async function liveInteraction(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
  operation:
    | 'snapshot'
    | 'gift'
    | 'like'
    | 'cohost.request'
    | 'cohost.cancel'
    | 'cohost.respond',
): Promise<ApplicationReply> {
  try {
    const result = await withAuthenticatedRoom(input, dependencies, (entry, attendee) => {
      switch (operation) {
        case 'gift':
          return dependencies.liveInteractionDirectory.send(entry, attendee, input.body);
        case 'like':
          return dependencies.liveInteractionDirectory.sendLike(entry, attendee, input.body);
        case 'cohost.request':
          return dependencies.liveInteractionDirectory.requestCohost(entry, attendee);
        case 'cohost.cancel':
          return dependencies.liveInteractionDirectory.cancelCohost(entry, attendee);
        case 'cohost.respond':
          return dependencies.liveInteractionDirectory.respondCohost(
            entry,
            attendee,
            String(input.body.userId ?? ''),
            String(input.body.action ?? ''),
          );
        case 'snapshot':
          return dependencies.liveInteractionDirectory.snapshot(entry, attendee);
      }
    });
    return reply(result);
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    dependencies.logError?.('live interaction failed', error);
    fail(502, 'live-interaction-failed', 'Unable to apply live interaction.');
  }
}

export async function postContentSnapshot(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
): Promise<ApplicationReply> {
  try {
    const result = await withAuthenticatedRoom(input, dependencies, (entry, attendee) => {
      const proof = String(input.body.roomOwnerCredential ?? '').trim();
      if (proof && !matchesRoomOwnerCredential(entry, proof)) {
        fail(403, 'forbidden', 'Invalid room owner credential.');
      }
      const isManager =
        Boolean(proof) || (entry.roomMode === 'broadcast' && attendee.role === 'host');
      if (!dependencies.sharedContentDirectory) {
        fail(503, 'unsupported-feature', 'Shared content directory is unavailable.');
      }
      return dependencies.sharedContentDirectory.snapshot(entry, attendee, isManager);
    });
    return reply(result);
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    dependencies.logError?.('shared content snapshot failed', error);
    fail(502, 'classroom-control-failed', 'Unable to load shared content.');
  }
}

export async function postContentAction(
  input: ApplicationInput,
  dependencies: InteractionApplicationDependencies,
): Promise<ApplicationReply> {
  try {
    const result = await withAuthenticatedRoom(input, dependencies, (entry, attendee) => {
      const proof = String(input.body.roomOwnerCredential ?? '').trim();
      if (proof && !matchesRoomOwnerCredential(entry, proof)) {
        fail(403, 'forbidden', 'Invalid room owner credential.');
      }
      const isManager =
        Boolean(proof) || (entry.roomMode === 'broadcast' && attendee.role === 'host');
      if (!dependencies.sharedContentDirectory) {
        fail(503, 'unsupported-feature', 'Shared content directory is unavailable.');
      }
      return dependencies.sharedContentDirectory.act(entry, attendee, isManager, input.body);
    });
    return reply(result);
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    dependencies.logError?.('shared content action failed', error);
    fail(502, 'classroom-control-failed', 'Unable to apply shared content action.');
  }
}

export const postLiveSnapshot = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'snapshot');
export const postLiveGift = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'gift');
export const postLiveLike = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'like');
export const postLiveCohostRequest = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'cohost.request');
export const postLiveCohostCancel = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'cohost.cancel');
export const postLiveCohostRespond = (input: ApplicationInput, dependencies: InteractionApplicationDependencies) =>
  liveInteraction(input, dependencies, 'cohost.respond');
