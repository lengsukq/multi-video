import { ProviderOperationError } from '../../providers/provider-registry.ts';
import { requireParticipantCredential } from '../../participant-credential.ts';
import { fail, reply, type ApplicationInput, type ApplicationReply } from '../application-protocol.ts';
import type { RoomApplicationDependencies } from './dependencies.ts';

/**
 * Issues or revokes a dedicated auxiliary `#content` publishing credential
 * for providers whose single participant token only allows one video track
 * (Amazon IVS Real-Time Stage).
 */
export async function postRoomsByCodeAuxiliaryToken(
  input: ApplicationInput,
  dependencies: Pick<
    RoomApplicationDependencies,
    'providerRegistry' | 'resolveRoom' | 'assertRoomOpen' | 'isRoomPartiallyClosed' | 'pruneStaleAttendees'
  >,
): Promise<ApplicationReply> {
  const {
    providerRegistry,
    resolveRoom,
    assertRoomOpen,
    isRoomPartiallyClosed,
    pruneStaleAttendees,
  } = dependencies;

  try {
    const entry = await resolveRoom(input.params.code);
    if (!entry) return fail(404, 'room-not-found', 'The requested room was not found.');
    assertRoomOpen(entry);
    if (isRoomPartiallyClosed(entry)) {
      return fail(409, 'room-closing', 'The room is partially closed.');
    }
    const participantId = String(input.body?.participantId ?? '').trim();
    if (!participantId) {
      return fail(400, 'invalid-argument', 'participantId is required.');
    }
    pruneStaleAttendees(entry, Date.now());
    const attendee = requireParticipantCredential(
      entry,
      participantId,
      input.body?.participantCredential,
    );
    if (attendee.role === 'viewer') {
      return fail(403, 'forbidden', 'Viewers cannot publish auxiliary screen tracks.');
    }
    const action = input.body?.action === 'revoke' ? 'revoke' : 'acquire';
    const provider = providerRegistry.requireConfigured(entry.provider);
    if (typeof provider.issueAuxiliaryMediaToken !== 'function') {
      return fail(
        400,
        'unsupported-feature',
        'Auxiliary content tokens are not required or supported by this provider.',
      );
    }
    const response = await provider.issueAuxiliaryMediaToken({
      entry,
      participantId,
      purpose: 'screen_share',
      action,
    });
    return reply(response);
  } catch (error) {
    if (error instanceof ProviderOperationError) throw error;
    console.error('auxiliary token operation failed', error);
    return fail(500, 'auxiliary-token-failed', 'Unable to manage auxiliary media token.');
  }
}
